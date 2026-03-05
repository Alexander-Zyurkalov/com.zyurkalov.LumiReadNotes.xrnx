-- H2MIDI-Pro Cursor Note Preview for Renoise
-- Tracks cursor position and sends the active notes at that position to
-- "H2MIDI-Pro (Port 2)" as MIDI.  Looks backwards through the
-- pattern to determine which notes are still sustaining, and sends
-- proper Note On / Note Off messages.
--
-- Also listens on "H2MIDI-Pro (Port 1)" for incoming notes. When a
-- note arrives that matches one we are already holding, we re-send
-- the Note On after 500ms so the keyboard LEDs re-light after the
-- user's own Note Off kills them.

------------------------------------------------------------------------
-- Global state
------------------------------------------------------------------------
local midi_output = nil          -- Port 2 (output to light keyboard)
local midi_input = nil           -- Port 1 (listen for user key presses)
local observers_attached = false

-- Tracked cursor position (used to detect changes)
local last_line_index = -1
local last_track_index = -1
local last_pattern_index = -1
local last_line_fingerprint = ""

-- Currently sounding notes per column: { [col_idx] = { note, velocity, channel } }
local active_notes = {}

-- Whether a delayed resend (call to update_preview) is pending
local resend_pending = false

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local OUTPUT_DEVICE_NAME = "Exquis"
local INPUT_DEVICE_NAME = "Exquis"
local DEFAULT_VELOCITY = 100
local DEFAULT_CHANNEL = 0       -- 0-based MIDI channel (channel 1)
local POLL_INTERVAL_MS = 50     -- How often we check for cursor movement
local RESEND_DELAY_MS = 500    -- Delay before re-sending a note after user press

------------------------------------------------------------------------
-- Renoise note-value constants
------------------------------------------------------------------------
local NOTE_OFF_VALUE = 120      -- The "OFF" marker in a note column
local NOTE_EMPTY_VALUE = 121    -- Empty / no note

------------------------------------------------------------------------
-- Low-level MIDI helpers
------------------------------------------------------------------------
local function send_note_on(note, velocity, channel)
    if midi_output and note >= 0 and note <= 119 then
        midi_output:send({ 0x90 + (channel % 16), note, velocity })
    end
end

local function send_note_off(note, channel)
    if midi_output and note >= 0 and note <= 119 then
        midi_output:send({ 0x80 + (channel % 16), note, 0 })
    end
end

-- Kill every note we are currently holding
local function all_notes_off()
    for _, info in pairs(active_notes) do
        send_note_off(info.note, info.channel)
    end
    active_notes = {}
end

-- Panic: send Note Off on every note on every channel
local function midi_panic()
    if not midi_output then
        return
    end
    for ch = 0, 15 do
        for n = 0, 127 do
            send_note_off(n, ch)
        end
    end
    active_notes = {}
end

------------------------------------------------------------------------
-- Delayed resend logic (single timer)
------------------------------------------------------------------------

-- Forward declaration (update_preview is defined further below)
local update_preview

local function resend_callback()
    -- Remove the one-shot timer
    if renoise.tool():has_timer(resend_callback) then
        renoise.tool():remove_timer(resend_callback)
    end
    resend_pending = false

    -- Clear active notes and fingerprint so update_preview re-sends everything
    active_notes = {}
    last_line_fingerprint = ""
    update_preview()
end

local cancel_resend

local function schedule_resend()
    if resend_pending then
        cancel_resend()
    end
    resend_pending = true
    renoise.tool():add_timer(resend_callback, RESEND_DELAY_MS)
end

cancel_resend = function()
    if not resend_pending then
        return
    end
    if renoise.tool():has_timer(resend_callback) then
        renoise.tool():remove_timer(resend_callback)
    end
    resend_pending = false
end

------------------------------------------------------------------------
-- Port 1 MIDI input callback
------------------------------------------------------------------------
local function input_midi_callback(message)
    local status = message[1]
    local note = message[2] or 0
    local command = status - (status % 16)  -- strip channel

    -- We care about Note Off (0x80) or Note On with velocity 0 (also Note Off)
    local is_note_off = (command == 0x80)
            or (command == 0x90 and (message[3] or 0) == 0)

    if not is_note_off then
        return
    end

    -- Check if this note is in our active set
    for _, info in pairs(active_notes) do
        if info.note == note then
            schedule_resend()
            return
        end
    end
end

------------------------------------------------------------------------
-- Pattern analysis
------------------------------------------------------------------------

-- Maximum number of previous patterns to scan when looking for a
-- sustaining note.  Keeps the search bounded to avoid runaway scans
-- in songs with hundreds of patterns.
local MAX_PATTERN_LOOKBACK = 8

-- Scan a single pattern_track backwards from `start_line` down to line 1
-- for `column_index`.  Returns one of:
--   { note, velocity, channel }  – found a real note
--   "off"                        – found an explicit Note Off
--   nil                          – reached the top without finding anything
local function scan_pattern_track(pattern_track, column_index, start_line)
    for l = start_line, 1, -1 do
        local line = pattern_track:line(l)
        if not line then
            return nil
        end

        local note_columns = line.note_columns
        if column_index > table.getn(note_columns) then
            return nil
        end

        local col = note_columns[column_index]
        local note_val = col.note_value

        if note_val == NOTE_OFF_VALUE then
            return "off"
        elseif note_val ~= NOTE_EMPTY_VALUE then
            local vol = col.volume_value
            local velocity = DEFAULT_VELOCITY
            if vol ~= 0xFF and vol <= 0x80 then
                velocity = math.max(1, math.min(127, math.floor(vol * 127 / 0x80 + 0.5)))
            end
            return {
                note = note_val,
                velocity = velocity,
                channel = DEFAULT_CHANNEL,
            }
        end
    end
    return nil  -- nothing found in this pattern
end

-- Walk backwards from `line_index` (inclusive) through the current
-- pattern, and – if nothing is found – continue into previous patterns
-- in the sequencer, up to MAX_PATTERN_LOOKBACK patterns back.
local function find_active_note_at(song, cur_seq_index, cur_track_index, column_index, line_index)
    local seq = song.sequencer.pattern_sequence

    for s = cur_seq_index, math.max(1, cur_seq_index - MAX_PATTERN_LOOKBACK), -1 do
        local pat = song:pattern(seq[s])
        local pt = pat.tracks[cur_track_index]
        if not pt then
            break
        end

        local start_line = (s == cur_seq_index) and line_index or pat.number_of_lines
        local result = scan_pattern_track(pt, column_index, start_line)
        if result == "off" then
            return nil
        end
        if result then
            return result
        end
    end

    return nil
end

------------------------------------------------------------------------
-- Core update – called by timer
------------------------------------------------------------------------

-- Build a short string that captures every note column's note + volume
-- on the current line so we can detect in-place edits.
local function line_fingerprint(pattern_track, line_index, num_columns)
    local parts = {}
    local line = pattern_track:line(line_index)
    if not line then
        return ""
    end
    local note_columns = line.note_columns
    for col = 1, num_columns do
        if col <= table.getn(note_columns) then
            local c = note_columns[col]
            parts[col] = c.note_value .. "," .. c.volume_value
        end
    end
    return table.concat(parts, ";")
end

update_preview = function()
    local song = renoise.song()

    -- Determine position and track context depending on play state
    local cur_line, cur_track, cur_pattern, cur_seq

    -- Stopped – use the edit-cursor position
    cur_line = song.selected_line_index
    cur_track = song.selected_track_index
    cur_pattern = song.selected_pattern_index
    cur_seq = song.selected_sequence_index

    -- Only work on sequencer (note) tracks
    local track = song:track(cur_track)
    if track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        all_notes_off()
        cancel_resend()
        last_line_fingerprint = ""
        return
    end

    local pattern_track = song:pattern(cur_pattern).tracks[cur_track]
    if not pattern_track then
        all_notes_off()
        cancel_resend()
        last_line_fingerprint = ""
        return
    end

    local num_columns = track.visible_note_columns

    -- Compute fingerprint to detect in-place edits (or line changes)
    local fp = line_fingerprint(pattern_track, cur_line, num_columns)

    -- Nothing to do if position hasn't moved AND content hasn't changed
    if cur_line == last_line_index
            and cur_track == last_track_index
            and cur_pattern == last_pattern_index
            and fp == last_line_fingerprint then
        return
    end

    last_line_index = cur_line
    last_track_index = cur_track
    last_pattern_index = cur_pattern
    last_line_fingerprint = fp

    -- Cancel pending resends – the context has changed
    cancel_resend()

    -- Build the set of notes that should be sounding right now
    local new_active = {}
    for col_idx = 1, num_columns do
        local info = find_active_note_at(song, cur_seq, cur_track, col_idx, cur_line)
        if info then
            new_active[col_idx] = info
        end
    end

    -- ---- Diff against previous state --------------------------------

    -- 1. Note Offs for notes that stopped or changed
    for col_idx, old in pairs(active_notes) do
        local new_info = new_active[col_idx]
        if not new_info
                or new_info.note ~= old.note
                or new_info.channel ~= old.channel then
            send_note_off(old.note, old.channel)
        end
    end

    -- 2. Note Ons for notes that are new or changed
    for col_idx, new_info in pairs(new_active) do
        local old = active_notes[col_idx]
        if not old
                or old.note ~= new_info.note
                or old.channel ~= new_info.channel then
            send_note_on(new_info.note, new_info.velocity, new_info.channel)
        end
    end

    active_notes = new_active
end

------------------------------------------------------------------------
-- Timer management
------------------------------------------------------------------------
local function start_timer()
    if not renoise.tool():has_timer(update_preview) then
        renoise.tool():add_timer(update_preview, POLL_INTERVAL_MS)
    end
end

local function stop_timer()
    if renoise.tool():has_timer(update_preview) then
        renoise.tool():remove_timer(update_preview)
    end
end

------------------------------------------------------------------------
-- Observers – invalidate tracked position to force re-evaluation
------------------------------------------------------------------------
local function on_track_changed()
    last_track_index = -1
end

local function on_pattern_changed()
    last_pattern_index = -1
end

local function attach_observers()
    if observers_attached then
        return
    end

    local song = renoise.song()

    if song.selected_track_index_observable:has_notifier(on_track_changed) == false then
        song.selected_track_index_observable:add_notifier(on_track_changed)
    end

    if song.selected_pattern_index_observable:has_notifier(on_pattern_changed) == false then
        song.selected_pattern_index_observable:add_notifier(on_pattern_changed)
    end

    observers_attached = true
end

local function detach_observers()
    if not observers_attached then
        return
    end

    local song = renoise.song()

    if song.selected_track_index_observable:has_notifier(on_track_changed) then
        song.selected_track_index_observable:remove_notifier(on_track_changed)
    end

    if song.selected_pattern_index_observable:has_notifier(on_pattern_changed) then
        song.selected_pattern_index_observable:remove_notifier(on_pattern_changed)
    end

    observers_attached = false
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------
local function initialize()
    -- Tear down previous session
    if midi_output then
        all_notes_off()
        midi_output:close()
        midi_output = nil
    end
    if midi_input then
        midi_input:close()
        midi_input = nil
    end
    detach_observers()
    stop_timer()
    cancel_resend()

    -- Reset state
    last_line_index = -1
    last_track_index = -1
    last_pattern_index = -1
    last_line_fingerprint = ""
    active_notes = {}

    -- Find and open the output device (Port 2)
    local output_devices = renoise.Midi.available_output_devices()
    for i = 1, table.getn(output_devices) do
        if output_devices[i] == OUTPUT_DEVICE_NAME then
            midi_output = renoise.Midi.create_output_device(OUTPUT_DEVICE_NAME)
            break
        end
    end

    -- Find and open the input device (Port 1)
    local input_devices = renoise.Midi.available_input_devices()
    for i = 1, table.getn(input_devices) do
        if input_devices[i] == INPUT_DEVICE_NAME then
            midi_input = renoise.Midi.create_input_device(INPUT_DEVICE_NAME, input_midi_callback)
            break
        end
    end

    if midi_output then
        print("H2MIDI-Pro Preview: Output connected to " .. OUTPUT_DEVICE_NAME)
    else
        print("H2MIDI-Pro Preview: Output device '" .. OUTPUT_DEVICE_NAME .. "' not found")
    end

    if midi_input then
        print("H2MIDI-Pro Preview: Input connected to " .. INPUT_DEVICE_NAME)
    else
        print("H2MIDI-Pro Preview: Input device '" .. INPUT_DEVICE_NAME .. "' not found")
    end

    if midi_output then
        attach_observers()
        start_timer()
    end
end

------------------------------------------------------------------------
-- Entry points
------------------------------------------------------------------------


-- Menu entry to reconnect / re-init
renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:Reconnect H2MIDI-Pro Preview",
    invoke = initialize
}

-- Menu entry for MIDI panic
renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:H2MIDI-Pro MIDI Panic",
    invoke = midi_panic
}

-- Cleanup on document release (song close)
renoise.tool().app_release_document_observable:add_notifier(function()
    all_notes_off()
    cancel_resend()
    detach_observers()
    stop_timer()
    if midi_output then
        midi_output:close()
        midi_output = nil
    end
    if midi_input then
        midi_input:close()
        midi_input = nil
    end
end)

renoise.tool().app_new_document_observable:add_notifier(initialize)