--
--
--  Synthetic Garden v0.89
--
--  Written by Skyler King
--
--  Four Track Scanning Looper

local util = require "util"
local fileselect = require "fileselect"

local NUM_LOOPS = 4
local MAX_REC = 30.0
local LOOP_EDGE_FADE = 0.010 -- 10 ms loop-boundary crossfade
local PITCH_RATE_SLEW = 0.030 -- smooth ordinary pitch changes
local DIRECTION_FADE_TIME = 0.008 -- 8 ms down + 8 ms up using Softcut gain slew
local DIRECTION_ZERO_HOLD = 0.005 -- 5 ms silent hold before and after the direction flip
local PHASE_QUANT = 0.001 -- 1 ms phase polling for tighter short-loop boundaries
local RECORD_END_TRIM = 0.030 -- trim 30 ms from recorded endpoint to avoid empty tail
local SLOT_GAP = 1.0
local SLOT_BASE = 1.0
local PAGE_NAMES = {"GARDEN", "RECORD", "TRIM", "RANGE", "DELAY"}
local MODE_NAMES = {"FORWARD", "REVERSE", "PING PONG", "STEP RAND", "SMOOTH RAND"}
local PLAY_MODE_NAMES = {"FORWARD", "REVERSE", "PING PONG"}
local PLAY_MODE_ICONS = {">", "<", "<>"}
local TRIM_MODE_NAMES = {"BOUND", "CHASE"}
local ZERO_CROSS_MODE_NAMES = {"ZX", "FREE"}

local page = 1

-- Optional Grid 128 performance controller.
-- First prototype: bottom-left five buttons select pages 1-5.
local g = nil
local grid_range_hold_x = nil
local grid_range_param_syncing = false

-- Row 8 x11-x15 scan-mode order:
-- Forward, Ping Pong, Reverse, Step Random, Smooth Random.
local grid_scan_mode_map = {1, 3, 2, 4, 5}

-- RECORD page pitch chord state.
local grid_pitch_hold_x = nil
local grid_pitch_chord_used = false

-- Full-row RECORD pitch map. Singles cover the anchor notes from -12 to +12;
-- selected adjacent pairs fill the missing semitones, with x8+x9 = 0.
local grid_pitch_single = {
  -12, -10, -9, -7, -6, -4, -3, -1,
    1,   3,  4,  6,  7,  9, 10, 12
}
local grid_pitch_chord = {
  [1] = -11,
  [3] = -8,
  [5] = -5,
  [7] = -2,
  [8] = 0,
  [9] = 2,
  [11] = 5,
  [13] = 8,
  [15] = 11
}

-- TRIM Grid range gesture state.
local grid_trim_hold_row = nil
local grid_trim_hold_x = nil
local grid_trim_pending_end = nil

-- When a newly selected Grid range excludes the current scanner position,
-- glide the live scanner into the nearest valid point instead of jumping.
local SCAN_RANGE_SLEW_TIME = 0.050
local scan_range_slew_active = false
local scan_range_slew_from = 0
local scan_range_slew_to = 0
local scan_range_slew_elapsed = 0

local k1_down = false
local k2_down = false
local k2_modified = false
local trim_param_syncing = false
local scanner_frozen = false
local trim_behavior_mode = 1 -- 1 = BOUND, 2 = CHASE
local zero_cross_mode = 1 -- 1 = ZERO X, 2 = FREE

local scan_pos = 0.0
local scan_start = 0.0
local scan_end = 1.0
local scan_width = 0.38
local scan_rate = 0.05
local scan_mode = 3
local auto_scan = false
local ping_dir = 1

local random_target = 0.5
local random_from = 0.5
local random_elapsed = 0.0
local random_duration = 1.0
local step_elapsed = 0.0

local selected_loop = 1
local loaded = {false, false, false, false}
local playing = {true, true, true, true}
local loop_len = {5.0, 5.0, 5.0, 5.0}
-- Non-destructive playback trim, measured from the beginning of each stored loop.
local trim_start = {0.0, 0.0, 0.0, 0.0}
local trim_end = {5.0, 5.0, 5.0, 5.0}
-- false = startup behavior: E2 moves Start while End stays fixed.
-- true = established loop window: E2 moves Start + End together at fixed length.
local trim_window_locked = {false, false, false, false}
local MIN_TRIM_LEN = 0.005

-- Cached downsampled Softcut buffer data for the TRIM waveform display.
local WAVEFORM_SAMPLES = 384 -- high-detail TRIM display render; compressed to OLED pixel columns
local ZERO_CROSS_WINDOW = 0.010 -- search +/- 10 ms around requested trim point
local ZERO_CROSS_SAMPLES = 512 -- high-resolution local render for zero-cross snapping
local waveform_samples = {{}, {}, {}, {}}
local pending_zero_cross_request = nil
local zero_cross_request_token = 0
-- Unsnapped edit targets. ZX can snap the audible boundary without causing
-- the next encoder detent to start from the previous snapped crossing.
local trim_edit_start = {0.0, 0.0, 0.0, 0.0}
local trim_edit_end = {5.0, 5.0, 5.0, 5.0}

-- TRIM encoder acceleration state. Slow movement stays precise; fast turns
-- travel farther. The step size itself is slewed so acceleration/deceleration
-- feels smooth rather than jumping abruptly between coarse resolutions.
local trim_encoder_last_time = {[2] = 0, [3] = 0}
local trim_encoder_step_ms = {[2] = 5, [3] = 5}

-- Full-waveform renders are tracked separately from tiny zero-cross renders.
local pending_waveform_render = {}

-- One internal loop clipboard for TRIM-page copy/paste.
-- Audio is copied into a reserved Softcut buffer region so the source loop
-- can later be changed or deleted without destroying the clipboard.
local CLIPBOARD_START = SLOT_BASE + NUM_LOOPS * (MAX_REC + SLOT_GAP)
local clipboard_has_audio = false
local clipboard_len = 0
local clipboard_trim_start = 0
local clipboard_trim_end = 0
local clipboard_trim_window_locked = false
local clipboard_play_mode = 1
local loop_pan = {-0.75, -0.25, 0.25, 0.75}
local loop_level = {1.0, 1.0, 1.0, 1.0}
local loop_rate = {1, 1, 1, 1}
local loop_semitones = {0, 0, 0, 0}
local loop_play_mode = {1, 1, 1, 1}
local loop_ping_dir = {1, 1, 1, 1}
local loop_gain = {0, 0, 0, 0}
-- Latest absolute Softcut playhead position for each loop voice.
-- Used only for the TRIM-page visual cursor.
local loop_playhead_pos = {0, 0, 0, 0}
local loop_transition_gain = {1, 1, 1, 1}
local loop_direction_busy = {false, false, false, false}
local loop_direction_token = {0, 0, 0, 0}
-- Live trim transition state. When a moved loop point passes the playhead,
-- temporary Softcut bounds let playback travel into the new loop naturally
-- without moving the playhead.
local loop_trim_transit = {false, false, false, false}
local loop_file = {"", "", "", ""}
local file_selecting = false

local recording = 0
local rec_started = 0
local rec_clock_id = nil

local scan_metro = nil
local last_tick = 0
local apply_scanner

-- Post-scanner stereo delay (Softcut voices 5 + 6, buffer 2)
local DELAY_VL = 5
local DELAY_VR = 6
local DELAY_L_START = 1.0
local DELAY_R_START = 5.0

local delay_bank = 1
local delay_param = 1
local DELAY_BANK_NAMES = {"CORE", "CHARACTER", "STEREO"}
local DELAY_PARAM_NAMES = {
  {"TIME", "FEEDBACK", "MIX"},
  {"TONE", "WOW", "FLUTTER"},
  {"SPREAD", "PING PONG", "WIDTH"}
}

local delay_time_ms = 450
local delay_feedback = 0.45
local delay_mix = 0.30
local delay_tone = 0
local delay_wow = 0.0
local delay_flutter = 0.0
local delay_spread = 0.08
local delay_pingpong = 0.0
local delay_width = 1.0

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function trim_encoder_step(n)
  local now = util.time()
  local last = trim_encoder_last_time[n] or 0
  local dt = last > 0 and (now - last) or 1
  trim_encoder_last_time[n] = now

  -- Base movement targets in milliseconds per encoder event.
  -- Slow = surgical; sustained fast turning = rapid travel.
  local target_ms = 5
  if dt <= 0.025 then
    target_ms = 70
  elseif dt <= 0.045 then
    target_ms = 35
  elseif dt <= 0.075 then
    target_ms = 15
  end

  local current_ms = trim_encoder_step_ms[n] or 5

  if dt > 0.16 then
    -- After a short pause, immediately return to fine editing.
    current_ms = 5
  else
    -- Slew toward the speed-dependent target. Acceleration rises gently,
    -- while deceleration settles back to precision a little faster.
    local alpha = target_ms > current_ms and 0.25 or 0.45
    current_ms = current_ms + (target_ms - current_ms) * alpha
  end

  current_ms = clamp(current_ms, 5, 100)
  trim_encoder_step_ms[n] = current_ms
  return current_ms / 1000
end

local function semitone_rate(semitones)
  return 2 ^ (semitones / 12)
end

local function refresh_loop_rate(i, slew_time)
  local base_rate = semitone_rate(loop_semitones[i])
  local direction = 1

  if loop_play_mode[i] == 2 then
    direction = -1
  elseif loop_play_mode[i] == 3 then
    direction = loop_ping_dir[i]
  end

  loop_rate[i] = base_rate * direction

  if recording ~= i then
    softcut.rate_slew_time(i, slew_time or PITCH_RATE_SLEW)
    softcut.rate(i, loop_rate[i])
  end
end

local function set_loop_pitch(i, semitones)
  loop_semitones[i] = clamp(math.floor(semitones + 0.5), -12, 12)
  refresh_loop_rate(i, PITCH_RATE_SLEW)
end

local function slot_start(i)
  return SLOT_BASE + (i - 1) * (MAX_REC + SLOT_GAP)
end

local function normalize_trim(i, changed)
  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  trim_start[i] = clamp(trim_start[i], 0, math.max(0, len - MIN_TRIM_LEN))
  trim_end[i] = clamp(trim_end[i], MIN_TRIM_LEN, len)

  if trim_end[i] - trim_start[i] < MIN_TRIM_LEN then
    if changed == "start" then
      trim_start[i] = math.max(0, trim_end[i] - MIN_TRIM_LEN)
    else
      trim_end[i] = math.min(len, trim_start[i] + MIN_TRIM_LEN)
    end
  end
end

local function apply_loop_trim(i, changed)
  normalize_trim(i, changed)
  if not loaded[i] then return end

  local base = slot_start(i)
  local active_len = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])
  softcut.fade_time(i, math.min(LOOP_EDGE_FADE, active_len * 0.10))
  softcut.loop_start(i, base + trim_start[i])
  softcut.loop_end(i, base + trim_end[i])
end

local function sync_trim_params(i)
  trim_param_syncing = true
  params:set("loop_" .. i .. "_trim_start_ms", math.floor(trim_start[i] * 1000 + 0.5))
  params:set("loop_" .. i .. "_trim_end_ms", math.floor(trim_end[i] * 1000 + 0.5))
  trim_param_syncing = false
end

local function shift_trim_window(i, delta_seconds)
  if not loaded[i] then return end

  local len = math.max(loop_len[i], MIN_TRIM_LEN)

  if not trim_window_locked[i] then
    -- Startup behavior: End stays fixed and only Start moves.
    trim_start[i] = clamp(
      trim_start[i] + delta_seconds,
      0,
      math.max(0, trim_end[i] - MIN_TRIM_LEN)
    )
  else
    -- Established loop behavior: Start and End are one fixed-length window.
    -- If either edge reaches a sample boundary, the whole window stops.
    local span = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])
    local max_start = math.max(0, len - span)
    local new_start = clamp(trim_start[i] + delta_seconds, 0, max_start)

    trim_start[i] = new_start
    trim_end[i] = new_start + span
  end

  apply_loop_trim(i)
  sync_trim_params(i)
end

local function reset_loop_trim(i)
  trim_start[i] = 0
  trim_end[i] = loop_len[i]
  trim_window_locked[i] = false
  apply_loop_trim(i)
  sync_trim_params(i)
end


local function direction_timing(i)
  local span = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])

  if span >= 0.050 then
    return 0.008, 0.005, 0.001, 0.002
  elseif span >= 0.020 then
    local t = (span - 0.020) / 0.030
    local fade = 0.003 + t * 0.005
    local hold = 0.001 + t * 0.004
    local inset = 0.0005 + t * 0.0005
    local settle = 0.0005 + t * 0.0015
    return fade, hold, inset, settle
  else
    local fade = clamp(span * 0.12, 0.0005, 0.0025)
    local hold = span <= 0.010 and 0 or clamp(span * 0.03, 0.0001, 0.0005)
    local inset = clamp(span * 0.03, 0.0001, 0.0005)
    local settle = clamp(span * 0.05, 0.0002, 0.0005)
    return fade, hold, inset, settle
  end
end

local function crossfade_direction(i, target_direction, snap_position)
  if recording == i then return end
  if loop_direction_busy[i] then return end

  target_direction = target_direction < 0 and -1 or 1
  loop_direction_token[i] = loop_direction_token[i] + 1
  local token = loop_direction_token[i]
  loop_direction_busy[i] = true

  clock.run(function()
    local fade_time, zero_hold, _, settle_time = direction_timing(i)

    -- Fade to zero inside Softcut's audio engine. Short loops automatically
    -- use a much faster fade so the turnaround can fit inside the loop.
    softcut.level_slew_time(i, fade_time)
    loop_transition_gain[i] = 0
    apply_scanner()

    clock.sleep(fade_time + settle_time)
    if token ~= loop_direction_token[i] then return end

    loop_transition_gain[i] = 0
    apply_scanner()
    if zero_hold > 0 then
      clock.sleep(zero_hold)
    end
    if token ~= loop_direction_token[i] then return end

    -- Optional bound correction / Ping Pong boundary snap while fully silent.
    if snap_position ~= nil then
      softcut.position(i, snap_position)
      loop_playhead_pos[i] = snap_position
    end

    loop_ping_dir[i] = target_direction
    loop_rate[i] = semitone_rate(loop_semitones[i]) * target_direction
    softcut.rate_slew_time(i, 0)
    softcut.rate(i, loop_rate[i])

    if zero_hold > 0 then
      clock.sleep(zero_hold)
    end
    if token ~= loop_direction_token[i] then return end

    softcut.level_slew_time(i, fade_time)
    loop_transition_gain[i] = 1
    apply_scanner()
    clock.sleep(fade_time + settle_time)

    if token ~= loop_direction_token[i] then return end
    loop_transition_gain[i] = 1
    apply_scanner()

    softcut.level_slew_time(i, 0.03)
    softcut.rate_slew_time(i, PITCH_RATE_SLEW)
    loop_direction_busy[i] = false
  end)
end

local function set_loop_play_mode(i, mode, restart)
  local previous_direction = (loop_rate[i] < 0) and -1 or 1
  local target_direction = previous_direction

  loop_play_mode[i] = clamp(mode, 1, #PLAY_MODE_NAMES)

  if loop_play_mode[i] == 1 then
    target_direction = 1
  elseif loop_play_mode[i] == 2 then
    target_direction = -1
  else
    -- Ping-pong begins in whichever direction the audio is already travelling.
    target_direction = previous_direction
  end

  if restart and loaded[i] and recording ~= i then
    -- Loading / pasting may intentionally start from a boundary.
    loop_ping_dir[i] = target_direction
    loop_rate[i] = semitone_rate(loop_semitones[i]) * target_direction
    softcut.rate_slew_time(i, 0)
    softcut.rate(i, loop_rate[i])

    local base = slot_start(i)
    if target_direction < 0 then
      softcut.position(i, base + trim_end[i] - 0.001)
    else
      softcut.position(i, base + trim_start[i])
    end
    softcut.rate_slew_time(i, PITCH_RATE_SLEW)
  elseif target_direction ~= previous_direction and loaded[i] then
    -- Live mode changes fade out, flip instantly while silent, then fade in.
    crossfade_direction(i, target_direction)
  else
    loop_ping_dir[i] = target_direction
  end
end


local function trim_transit_margin(i)
  local span = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])
  return math.min(0.010, math.max(0.001, span * 0.25))
end

local function set_trim_transport_bounds(i, start_rel, end_rel)
  local len = math.max(loop_len[i], MIN_TRIM_LEN)

  start_rel = clamp(start_rel, 0, math.max(0, len - MIN_TRIM_LEN))
  end_rel = clamp(end_rel, start_rel + MIN_TRIM_LEN, len)

  local base = slot_start(i)
  local active_len = math.max(MIN_TRIM_LEN, end_rel - start_rel)
  softcut.fade_time(i, math.min(LOOP_EDGE_FADE, active_len * 0.10))
  softcut.loop_start(i, base + start_rel)
  softcut.loop_end(i, base + end_rel)
end

local function finish_trim_transit(i)
  if not loop_trim_transit[i] then return end
  loop_trim_transit[i] = false
  apply_loop_trim(i)
end

local function start_trim_transit(i)
  if not loaded[i] or not playing[i] or recording == i then
    loop_trim_transit[i] = false
    apply_loop_trim(i)
    return
  end

  local position = loop_playhead_pos[i]
  if position == nil or position <= 0 then
    loop_trim_transit[i] = false
    apply_loop_trim(i)
    return
  end

  local base = slot_start(i)
  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  local sample_end = base + len
  local new_start = base + trim_start[i]
  local new_end = base + trim_end[i]

  -- If the playhead is still inside the newly selected loop, the new
  -- zero-crossing boundaries can become active immediately.
  if position >= new_start and position <= new_end then
    loop_trim_transit[i] = false
    apply_loop_trim(i)
    return
  end

  loop_trim_transit[i] = true

  local pos_rel = clamp(position - base, 0, len)
  local margin = trim_transit_margin(i)
  local target_direction = (loop_rate[i] < 0) and -1 or 1
  local temp_start = trim_start[i]
  local temp_end = trim_end[i]

  if loop_play_mode[i] == 3 then
    -- PING PONG: reverse in place only when needed so the playhead heads
    -- directly toward the newly selected loop window.
    if position > new_end then
      target_direction = -1
      temp_start = trim_start[i]
      temp_end = math.min(len, math.max(pos_rel + margin, trim_end[i] + MIN_TRIM_LEN))
    else -- position < new_start
      target_direction = 1
      temp_start = math.max(0, math.min(pos_rel - margin, trim_start[i] - MIN_TRIM_LEN))
      temp_end = trim_end[i]
    end

  elseif loop_play_mode[i] == 1 then
    -- FORWARD: never reverse. If the new range is ahead, simply travel into it.
    -- If it is behind, make a short temporary forward wrap back to new Start.
    target_direction = 1
    if position < new_start then
      temp_start = math.max(0, math.min(pos_rel - margin, trim_start[i] - MIN_TRIM_LEN))
      temp_end = trim_end[i]
    else -- position > new_end
      temp_start = trim_start[i]
      temp_end = math.min(len, math.max(pos_rel + margin, trim_end[i] + MIN_TRIM_LEN))
    end

  else -- REVERSE
    -- REVERSE: never reverse. If the new range is behind, travel directly
    -- into it. If it is ahead, use a short reverse wrap back to new End.
    target_direction = -1
    if position > new_end then
      temp_start = trim_start[i]
      temp_end = math.min(len, math.max(pos_rel + margin, trim_end[i] + MIN_TRIM_LEN))
    else -- position < new_start
      temp_start = math.max(0, math.min(pos_rel - margin, trim_start[i] - MIN_TRIM_LEN))
      temp_end = trim_end[i]
    end
  end

  set_trim_transport_bounds(i, temp_start, temp_end)

  -- Ping Pong may need an in-place direction change. Forward and Reverse keep
  -- their assigned directions. No softcut.position() call is used here.
  local current_direction = (loop_rate[i] < 0) and -1 or 1
  if target_direction ~= current_direction and not loop_direction_busy[i] then
    crossfade_direction(i, target_direction)
  end
end

local function handle_trim_transit(i, position)
  if not loop_trim_transit[i] then return false end

  if not loaded[i] or not playing[i] or recording == i then
    finish_trim_transit(i)
    return true
  end

  local base = slot_start(i)
  local new_start = base + trim_start[i]
  local new_end = base + trim_end[i]

  -- Once playback naturally lands inside the new zero-crossing loop window,
  -- make those exact boundaries active. The playhead itself is never moved.
  if position >= new_start and position <= new_end then
    finish_trim_transit(i)
    return true
  end

  -- If Ping Pong trim points move again during transit, keep steering toward
  -- the new window with a clean in-place direction flip when necessary.
  if loop_play_mode[i] == 3 and not loop_direction_busy[i] then
    local desired = nil
    if position > new_end then
      desired = -1
    elseif position < new_start then
      desired = 1
    end

    local current = (loop_rate[i] < 0) and -1 or 1
    if desired ~= nil and desired ~= current then
      crossfade_direction(i, desired)
    end
  end

  return true
end


local function enforce_bound_transport(i, position)
  if trim_behavior_mode ~= 1 then return false end
  if not loaded[i] or not playing[i] or recording == i then return false end
  if loop_direction_busy[i] then
    local base = slot_start(i)
    local start_pos = base + trim_start[i]
    local end_pos = base + trim_end[i]
    return position < start_pos or position > end_pos
  end

  local base = slot_start(i)
  local start_pos = base + trim_start[i]
  local end_pos = base + trim_end[i]

  if position >= start_pos and position <= end_pos then
    return false
  end

  local _, _, inset = direction_timing(i)
  local target_direction
  local snap_position

  if loop_play_mode[i] == 1 then
    target_direction = 1
    snap_position = math.min(end_pos, start_pos + inset)
  elseif loop_play_mode[i] == 2 then
    target_direction = -1
    snap_position = math.max(start_pos, end_pos - inset)
  else
    if position > end_pos then
      target_direction = -1
      snap_position = math.max(start_pos, end_pos - inset)
    else
      target_direction = 1
      snap_position = math.min(end_pos, start_pos + inset)
    end
  end

  crossfade_direction(i, target_direction, snap_position)
  return true
end

local function on_loop_phase(voice, position)
  if voice < 1 or voice > NUM_LOOPS then return end

  -- Keep a live playhead position for every loop, regardless of play mode.
  loop_playhead_pos[voice] = position

  if trim_behavior_mode == 2 then
    if handle_trim_transit(voice, position) then return end
  else
    if loop_trim_transit[voice] then
      loop_trim_transit[voice] = false
      apply_loop_trim(voice)
    end
    if enforce_bound_transport(voice, position) then return end
  end

  if not loaded[voice] or not playing[voice] then return end
  if recording == voice or loop_play_mode[voice] ~= 3 then return end
  if loop_direction_busy[voice] then return end

  local base = slot_start(voice)
  local start_pos = base + trim_start[voice]
  local end_pos = base + trim_end[voice]
  local span = math.max(MIN_TRIM_LEN, end_pos - start_pos)

  -- Adaptive short-loop turnaround timing keeps the fade/guard proportional
  -- to the loop instead of allowing a 5 ms loop to use a 13+ ms transition.
  local fade_time, _, inset, settle_time = direction_timing(voice)
  local travel_per_poll = math.abs(loop_rate[voice]) * PHASE_QUANT
  local fade_travel = math.abs(loop_rate[voice]) * (fade_time + settle_time)
  local guard = math.min(
    math.max(inset * 2, fade_travel + travel_per_poll * 1.5 + inset),
    span * 0.25
  )

  if loop_ping_dir[voice] > 0 and position >= end_pos - guard then
    crossfade_direction(voice, -1, math.max(start_pos, end_pos - inset))
  elseif loop_ping_dir[voice] < 0 and position <= start_pos + guard then
    crossfade_direction(voice, 1, math.min(end_pos, start_pos + inset))
  end
end


local function find_nearest_zero_crossing(samples, render_start, sec_per_sample, target_abs)
  if samples == nil or #samples < 2 then return nil end
  if sec_per_sample == nil or sec_per_sample <= 0 then return nil end

  local best_pos = nil
  local best_dist = math.huge

  for n = 1, #samples - 1 do
    local a = samples[n]
    local b = samples[n + 1]

    if a ~= nil and b ~= nil then
      local crossing = false

      if a == 0 then
        crossing = true
      elseif b == 0 then
        crossing = true
      elseif (a < 0 and b > 0) or (a > 0 and b < 0) then
        crossing = true
      end

      if crossing then
        local frac = 0
        if a == 0 then
          frac = 0
        elseif b == 0 then
          frac = 1
        else
          local denom = math.abs(a) + math.abs(b)
          frac = denom > 0 and (math.abs(a) / denom) or 0.5
        end

        local pos = render_start + ((n - 1) + frac) * sec_per_sample
        local dist = math.abs(pos - target_abs)

        if dist < best_dist then
          best_dist = dist
          best_pos = pos
        end
      end
    end
  end

  return best_pos
end


local function apply_trim_target(i, target_rel, kind, span)
  if not loaded[i] then return end

  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  target_rel = clamp(target_rel, 0, len)

  if kind == "end" then
    trim_end[i] = clamp(target_rel, trim_start[i] + MIN_TRIM_LEN, len)
    trim_window_locked[i] = true

  elseif kind == "start_locked" then
    span = math.max(MIN_TRIM_LEN, span or (trim_end[i] - trim_start[i]))
    local max_start = math.max(0, len - span)
    trim_start[i] = clamp(target_rel, 0, max_start)
    trim_end[i] = trim_start[i] + span

  else -- start_unlocked
    trim_start[i] = clamp(target_rel, 0, math.max(0, trim_end[i] - MIN_TRIM_LEN))
  end

  normalize_trim(i, kind == "end" and "end" or "start")

  if trim_behavior_mode == 2 then
    start_trim_transit(i)
  else
    loop_trim_transit[i] = false
    apply_loop_trim(i, kind == "end" and "end" or "start")
    local position = loop_playhead_pos[i]
    if position ~= nil and position > 0 then
      enforce_bound_transport(i, position)
    end
  end

  sync_trim_params(i)
  redraw()
end

local function apply_free_trim(i, target_rel, kind, span)
  -- FREE mode intentionally skips the local waveform render and zero-cross
  -- search. The requested trim value is applied directly.
  apply_trim_target(i, target_rel, kind, span)
end

local request_zero_cross

local function finish_zero_cross_request(req, snapped_abs)
  if req == nil then return end
  if req.token ~= zero_cross_request_token then return end
  if not loaded[req.loop] then return end

  local i = req.loop
  local base = slot_start(i)
  local snapped_rel = snapped_abs and (snapped_abs - base) or req.target_rel

  apply_trim_target(i, snapped_rel, req.kind, req.span)

  local queued_end = grid_trim_pending_end
  grid_trim_pending_end = nil
  pending_zero_cross_request = nil

  if queued_end ~= nil and queued_end.loop == i then
    request_zero_cross(i, queued_end.target_rel, "end")
  end
end

request_zero_cross = function(i, target_rel, kind, span)
  if not loaded[i] then return end

  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  local base = slot_start(i)

  if kind == "end" then
    target_rel = clamp(target_rel, trim_start[i] + MIN_TRIM_LEN, len)
  elseif kind == "start_locked" then
    span = math.max(MIN_TRIM_LEN, span or (trim_end[i] - trim_start[i]))
    target_rel = clamp(target_rel, 0, math.max(0, len - span))
  else
    target_rel = clamp(target_rel, 0, math.max(0, trim_end[i] - MIN_TRIM_LEN))
  end

  local target_abs = base + target_rel
  local search_min_rel = math.max(0, target_rel - ZERO_CROSS_WINDOW)
  local search_max_rel = math.min(len, target_rel + ZERO_CROSS_WINDOW)

  if kind == "end" then
    search_min_rel = math.max(search_min_rel, trim_start[i] + MIN_TRIM_LEN)
  elseif kind == "start_locked" then
    search_max_rel = math.min(search_max_rel, math.max(0, len - span))
  else
    search_max_rel = math.min(search_max_rel, math.max(0, trim_end[i] - MIN_TRIM_LEN))
  end

  local render_start = base + search_min_rel
  local render_duration = math.max(0.001, search_max_rel - search_min_rel)

  zero_cross_request_token = zero_cross_request_token + 1
  pending_zero_cross_request = {
    token = zero_cross_request_token,
    loop = i,
    kind = kind,
    span = span,
    target_rel = target_rel,
    target_abs = target_abs,
    render_start = render_start,
    render_duration = render_duration,
    expected_sec_per_sample = render_duration / ZERO_CROSS_SAMPLES
  }

  softcut.render_buffer(1, render_start, render_duration, ZERO_CROSS_SAMPLES)
end


local function sync_trim_edit_targets(i)
  trim_edit_start[i] = trim_start[i]
  trim_edit_end[i] = trim_end[i]
end

local function request_waveform(i)
  if not loaded[i] or loop_len[i] <= 0 then
    waveform_samples[i] = {}
    pending_waveform_render[i] = nil
    return
  end

  local render_start = slot_start(i)
  local duration = loop_len[i]
  pending_waveform_render[i] = {
    start = render_start,
    expected_sec_per_sample = duration / WAVEFORM_SAMPLES
  }
  softcut.render_buffer(1, render_start, duration, WAVEFORM_SAMPLES)
end

local function on_waveform_render(ch, start_pos, sec_per_sample, samples)
  if ch ~= 1 then return end

  -- First classify dedicated high-resolution zero-cross search renders.
  local req = pending_zero_cross_request
  if req ~= nil then
    local start_match = math.abs(start_pos - req.render_start) < 0.001
    local step_match = sec_per_sample ~= nil and math.abs(sec_per_sample - req.expected_sec_per_sample) <
      math.max(0.00005, req.expected_sec_per_sample * 0.35)
    local count_match = samples ~= nil and #samples >= math.floor(ZERO_CROSS_SAMPLES * 0.75)

    if start_match and step_match and count_match then
      local snapped_abs = find_nearest_zero_crossing(samples, start_pos, sec_per_sample, req.target_abs)
      finish_zero_cross_request(req, snapped_abs)
      return
    end
  end

  -- Only a render explicitly requested as a full display waveform may replace
  -- waveform_samples. Tiny ZX search renders are ignored here.
  for i = 1, NUM_LOOPS do
    local pending = pending_waveform_render[i]
    if pending ~= nil then
      local start_match = math.abs(start_pos - pending.start) < 0.001
      local step_match = sec_per_sample ~= nil and
        math.abs(sec_per_sample - pending.expected_sec_per_sample) <
        math.max(0.0001, pending.expected_sec_per_sample * 0.35)
      local count_match = samples ~= nil and #samples <= math.ceil(WAVEFORM_SAMPLES * 1.25)

      if start_match and step_match and count_match then
        waveform_samples[i] = samples or {}
        pending_waveform_render[i] = nil
        redraw()
        return
      end
    end
  end

  -- Unknown render: deliberately ignore it rather than flattening/replacing
  -- the visible waveform.
end

local function copy_loop_to_clipboard(i)
  if not loaded[i] or recording ~= 0 then return end

  clipboard_len = loop_len[i]
  clipboard_trim_start = trim_start[i]
  clipboard_trim_end = trim_end[i]
  clipboard_trim_window_locked = trim_window_locked[i]
  clipboard_play_mode = loop_play_mode[i]

  softcut.buffer_clear_region_channel(1, CLIPBOARD_START, MAX_REC, 0.02, 0)
  softcut.buffer_copy_mono(
    1, 1,
    slot_start(i), CLIPBOARD_START,
    clipboard_len,
    0.01,
    0
  )

  clipboard_has_audio = true
  print("Synthetic Garden: copied loop " .. i)
end

local function paste_clipboard_to_loop(i)
  if not clipboard_has_audio or loaded[i] or recording ~= 0 then return end
  loop_trim_transit[i] = false

  local dst = slot_start(i)
  softcut.buffer_clear_region_channel(1, dst, MAX_REC, 0.02, 0)
  softcut.buffer_copy_mono(
    1, 1,
    CLIPBOARD_START, dst,
    clipboard_len,
    0.01,
    0
  )

  loop_len[i] = clipboard_len
  trim_start[i] = clipboard_trim_start
  trim_end[i] = clipboard_trim_end
  sync_trim_edit_targets(i)
  trim_window_locked[i] = clipboard_trim_window_locked
  loop_play_mode[i] = clipboard_play_mode
  loaded[i] = true
  playing[i] = true
  loop_file[i] = ""

  apply_loop_trim(i)
  sync_trim_params(i)
  loop_playhead_pos[i] = dst + trim_start[i]
  set_loop_play_mode(i, loop_play_mode[i], true)
  softcut.play(i, 1)

  request_waveform(i)
  apply_scanner()
  redraw()
  print("Synthetic Garden: pasted loop to track " .. i)
end

local function delete_loop(i)
  zero_cross_request_token = zero_cross_request_token + 1
  pending_zero_cross_request = nil

  if recording == i then
    finish_recording()
  end

  softcut.rec(i, 0)
  softcut.rec_level(i, 0)
  softcut.play(i, 0)
  softcut.buffer_clear_region_channel(1, slot_start(i), MAX_REC, 0.02, 0)

  loaded[i] = false
  playing[i] = false
  loop_trim_transit[i] = false
  loop_len[i] = 5.0
  trim_start[i] = 0
  trim_end[i] = 5.0
  sync_trim_edit_targets(i)
  trim_window_locked[i] = false
  loop_play_mode[i] = 1
  loop_ping_dir[i] = 1
  loop_file[i] = ""
  waveform_samples[i] = {}
  loop_playhead_pos[i] = 0

  apply_scanner()
  redraw()
  print("Synthetic Garden: deleted loop " .. i)
end

local function loop_center(i)
  -- Leaves equal silence space beyond loop 1 and loop 4.
  -- 0.0 = far-left silence, 1.0 = far-right silence.
  return i / (NUM_LOOPS + 1)
end

local function range_span()
  return math.max(0, scan_end - scan_start)
end

local function keep_scan_in_range()
  scan_pos = clamp(scan_pos, scan_start, scan_end)
end

local function choose_random_target()
  local span = range_span()
  if span < 0.0001 then
    random_target = scan_start
  else
    random_target = scan_start + math.random() * span
  end
end

local function reset_smooth_random()
  random_from = scan_pos
  choose_random_target()
  random_elapsed = 0
  random_duration = math.max(0.05, 1.0 / math.max(scan_rate, 0.005))
end

local function scanner_weights(pos)
  -- A-144-ish overlapping triangular windows.
  -- At narrow width the loops become short/discrete.
  -- At wide width, multiple loops overlap.
  local half_width = 0.025 + (scan_width * 0.30)
  local weights = {}
  local sum = 0

  for i = 1, NUM_LOOPS do
    local dist = math.abs(pos - loop_center(i))
    local w = math.max(0, 1 - (dist / half_width))
    weights[i] = w
    sum = sum + w
  end

  -- Prevent broad overlap from simply getting louder.
  if sum > 1 then
    for i = 1, NUM_LOOPS do
      weights[i] = weights[i] / sum
    end
  end

  return weights
end


local function delay_times()
  local base = delay_time_ms / 1000
  local spread = delay_spread * 0.12
  local left = clamp(base * (1 - spread), 0.03, 2.0)
  local right = clamp(base * (1 + spread), 0.03, 2.0)
  return left, right
end

local function set_delay_tone()
  local t = clamp(delay_tone / 100, -1, 1)
  local dry, lp, hp = 1, 0, 0
  local fc = 12000

  if t < -0.001 then
    local a = -t
    dry = 1 - a
    lp = a
    hp = 0
    fc = 18000 * ((220 / 18000) ^ a)
  elseif t > 0.001 then
    local a = t
    dry = 1 - a
    lp = 0
    hp = a
    fc = 25 * ((6500 / 25) ^ a)
  end

  for _, v in ipairs({DELAY_VL, DELAY_VR}) do
    softcut.pre_filter_dry(v, dry)
    softcut.pre_filter_lp(v, lp)
    softcut.pre_filter_hp(v, hp)
    softcut.pre_filter_bp(v, 0)
    softcut.pre_filter_br(v, 0)
    softcut.pre_filter_fc(v, fc)
    softcut.pre_filter_rq(v, 0.8)
  end
end


local function apply_delay_params()
  local lt, rt = delay_times()

  -- Keep loop crossfades short relative to the delay time.
  -- A fixed 20 ms fade is too large when the delay itself is only 30 ms.
  local shortest = math.min(lt, rt)
  local delay_fade = clamp(shortest * 0.15, 0.002, 0.010)
  softcut.fade_time(DELAY_VL, delay_fade)
  softcut.fade_time(DELAY_VR, delay_fade)

  softcut.loop_start(DELAY_VL, DELAY_L_START)
  softcut.loop_end(DELAY_VL, DELAY_L_START + lt)

  softcut.loop_start(DELAY_VR, DELAY_R_START)
  softcut.loop_end(DELAY_VR, DELAY_R_START + rt)

  local pp = clamp(delay_pingpong, 0, 1)
  local self_fb = delay_feedback * (1 - pp)
  local cross_fb = delay_feedback * pp

  softcut.pre_level(DELAY_VL, self_fb)
  softcut.pre_level(DELAY_VR, self_fb)
  softcut.level_cut_cut(DELAY_VL, DELAY_VR, cross_fb)
  softcut.level_cut_cut(DELAY_VR, DELAY_VL, cross_fb)

  local wet = math.sin(delay_mix * math.pi * 0.5)
  softcut.level(DELAY_VL, wet)
  softcut.level(DELAY_VR, wet)

  softcut.pan(DELAY_VL, -delay_width)
  softcut.pan(DELAY_VR, delay_width)

  set_delay_tone()
end

local function update_delay_mod(now)
  local wow_depth = delay_wow * 0.012
  local flutter_depth = delay_flutter * 0.006

  local wow = math.sin(now * 2 * math.pi * 0.22) * wow_depth
  local fl_l = math.sin(now * 2 * math.pi * 5.3) * flutter_depth
  local fl_r = math.sin((now * 2 * math.pi * 5.9) + 1.7) * flutter_depth

  softcut.rate(DELAY_VL, 1 + wow + fl_l)
  softcut.rate(DELAY_VR, 1 + wow + fl_r)
end

local function pan_gains(p)
  local x = clamp(p, -1, 1)
  local left = math.sqrt((1 - x) * 0.5)
  local right = math.sqrt((1 + x) * 0.5)
  return left, right
end

apply_scanner = function()
  local weights = scanner_weights(scan_pos)
  local dry = math.cos(delay_mix * math.pi * 0.5)

  for i = 1, NUM_LOOPS do
    local audible = loaded[i] and playing[i]
    local g = audible and (weights[i] * loop_level[i] * loop_transition_gain[i]) or 0
    loop_gain[i] = g

    -- Dry path keeps each loop's normal pan.
    softcut.level(i, g * dry)

    -- Recorded/scanned loop playback always feeds the stereo delay.
    local lg, rg = pan_gains(loop_pan[i])
    softcut.level_cut_cut(i, DELAY_VL, g * lg * 0.80)
    softcut.level_cut_cut(i, DELAY_VR, g * rg * 0.80)
  end
end

local function stop_record_clock()
  if rec_clock_id ~= nil then
    clock.cancel(rec_clock_id)
    rec_clock_id = nil
  end
end

local function finish_recording()
  if recording == 0 then return end

  local i = recording
  local elapsed = clamp(util.time() - rec_started, 0.10, MAX_REC)

  -- The Lua wall clock can run slightly ahead of Softcut's actual record head.
  -- Trim a tiny amount from the end so the loop closes inside recorded audio
  -- instead of including a few milliseconds of unwritten buffer.
  elapsed = math.max(0.10, elapsed - RECORD_END_TRIM)

  stop_record_clock()

  softcut.rec(i, 0)
  softcut.rec_level(i, 0)
  softcut.pre_level(i, 1)

  loop_len[i] = elapsed
  trim_start[i] = 0
  trim_end[i] = elapsed
  trim_window_locked[i] = false
  softcut.fade_time(i, math.min(LOOP_EDGE_FADE, elapsed * 0.10))
  softcut.loop_start(i, slot_start(i))
  softcut.loop_end(i, slot_start(i) + elapsed)
  softcut.position(i, slot_start(i))
  loop_playhead_pos[i] = slot_start(i)
  softcut.rate(i, loop_rate[i])
  softcut.play(i, 1)

  loaded[i] = true
  playing[i] = true
  recording = 0

  sync_trim_params(i)
  request_waveform(i)
  apply_scanner()
  redraw()
end

local function start_recording(i)
  loop_trim_transit[i] = false
  zero_cross_request_token = zero_cross_request_token + 1
  pending_zero_cross_request = nil

  if recording ~= 0 then
    finish_recording()
  end

  selected_loop = i
  local start = slot_start(i)

  -- Erase only this loop's thirty-second slot.
  softcut.buffer_clear_region_channel(1, start, MAX_REC, 0.02, 0)

  loaded[i] = false
  playing[i] = true
  waveform_samples[i] = {}
  loop_len[i] = MAX_REC
  trim_start[i] = 0
  trim_end[i] = MAX_REC
  sync_trim_edit_targets(i)
  trim_window_locked[i] = false
  loop_play_mode[i] = 1
  loop_ping_dir[i] = 1

  softcut.loop_start(i, start)
  softcut.loop_end(i, start + MAX_REC)
  softcut.position(i, start)
  softcut.rate(i, 1)
  softcut.loop(i, 1)
  softcut.pre_level(i, 0)
  softcut.rec_level(i, 1)
  softcut.rec(i, 1)
  softcut.play(i, 1)

  recording = i
  rec_started = util.time()

  stop_record_clock()
  rec_clock_id = clock.run(function()
    clock.sleep(MAX_REC)
    if recording == i then
      -- Mark the timer finished before closing the loop so we do not
      -- attempt to cancel the coroutine from inside itself.
      rec_clock_id = nil
      finish_recording()
    end
  end)

  apply_scanner()
  redraw()
end


local function import_audio_file(file_path, i)
  loop_trim_transit[i] = false
  zero_cross_request_token = zero_cross_request_token + 1
  pending_zero_cross_request = nil
  file_selecting = false

  if file_path == "cancel" or file_path == nil then
    redraw()
    return
  end

  if recording ~= 0 then
    finish_recording()
  end

  local channels, samples, samplerate = audio.file_info(file_path)
  if channels == nil or samples == nil or samplerate == nil then
    print("Synthetic Garden: could not read audio file: " .. tostring(file_path))
    redraw()
    return
  end

  local duration = math.min(samples / samplerate, MAX_REC)
  duration = math.max(duration, 0.10)

  local start = slot_start(i)

  softcut.buffer_clear_region_channel(1, start, MAX_REC, 0.02, 0)
  softcut.rec(i, 0)
  softcut.rec_level(i, 0)
  softcut.pre_level(i, 1)

  if channels >= 2 then
    softcut.buffer_read_mono(file_path, 0, start, duration, 1, 1, 0, 0.5)
    softcut.buffer_read_mono(file_path, 0, start, duration, 2, 1, 1, 0.5)
  else
    softcut.buffer_read_mono(file_path, 0, start, duration, 1, 1, 0, 1)
  end

  loop_len[i] = duration
  trim_start[i] = 0
  trim_end[i] = duration
  sync_trim_edit_targets(i)
  trim_window_locked[i] = false
  loop_play_mode[i] = 1
  loop_ping_dir[i] = 1
  loaded[i] = true
  playing[i] = true
  loop_file[i] = file_path
  sync_trim_params(i)

  softcut.fade_time(i, math.min(LOOP_EDGE_FADE, duration * 0.10))
  softcut.loop_start(i, start)
  softcut.loop_end(i, start + duration)
  loop_playhead_pos[i] = start
  set_loop_play_mode(i, 1, true)
  softcut.play(i, 1)

  if samplerate ~= 48000 then
    print("Synthetic Garden: imported " .. samplerate .. " Hz file; 48 kHz is recommended for accurate Softcut playback.")
  end

  request_waveform(i)
  apply_scanner()
  redraw()
end

local function choose_audio_file(i)
  file_selecting = true
  fileselect.enter(_path.audio, function(file_path)
    import_audio_file(file_path, i)
  end, "audio")
end

local function toggle_play(i)
  if not loaded[i] then return end
  playing[i] = not playing[i]
  softcut.play(i, playing[i] and 1 or 0)
  if playing[i] then
    softcut.position(i, slot_start(i) + (loop_rate[i] < 0 and trim_end[i] - 0.01 or trim_start[i]))
  end
  apply_scanner()
end

local function toggle_direction(i)
  loop_rate[i] = -loop_rate[i]
  softcut.rate(i, loop_rate[i])
  if loaded[i] then
    if loop_rate[i] < 0 then
      softcut.position(i, slot_start(i) + trim_end[i] - 0.01)
    else
      softcut.position(i, slot_start(i) + trim_start[i])
    end
  end
end

local function normalize_range(changed)
  if scan_start > scan_end then
    -- Let the controls cross naturally instead of getting stuck.
    if changed == "start" then
      scan_end = scan_start
    else
      scan_start = scan_end
    end
  end
  keep_scan_in_range()
  reset_smooth_random()
end


local function percent_string(p)
  return string.format("%d%%", p:get())
end

local function signed_percent_string(p)
  return string.format("%+d%%", p:get())
end

local function semitone_string(p)
  return string.format("%+d st", p:get())
end

local function rate_string(p)
  return string.format("%.3f Hz", p:get() / 1000)
end

local function trim_ms_string(p)
  return string.format("%.3f s", p:get() / 1000)
end

local function setup_mappable_params()
  -- SCANNER
  params:add_separator("sg_scanner", "SYNTHETIC GARDEN - SCANNER")

  params:add_number("scan_position", "Position", 0, 100, math.floor(scan_pos * 100 + 0.5), percent_string)
  params:set_action("scan_position", function(x)
    if not auto_scan then
      scan_pos = clamp(x / 100, 0, 1)
      apply_scanner()
      redraw()
    end
  end)

  params:add_number("scan_width", "Width", 0, 100, math.floor(scan_width * 100 + 0.5), percent_string)
  params:set_action("scan_width", function(x)
    scan_width = clamp(x / 100, 0, 1)
    apply_scanner()
    redraw()
  end)

  params:add_number("scan_rate_mhz", "Rate", 5, 10000, math.floor(scan_rate * 1000 + 0.5), rate_string)
  params:set_action("scan_rate_mhz", function(x)
    scan_rate = clamp(x / 1000, 0.005, 10.0)
    if scan_mode == 5 then reset_smooth_random() end
    redraw()
  end)

  params:add_option("scan_mode", "Mode", MODE_NAMES, scan_mode)
  params:set_action("scan_mode", function(x)
    scan_mode = clamp(x, 1, #MODE_NAMES)
    step_elapsed = 0
    ping_dir = 1
    reset_smooth_random()
    redraw()
  end)

  params:add_number("scan_start", "Start", 0, 100, math.floor(scan_start * 100 + 0.5), percent_string)
  params:set_action("scan_start", function(x)
    if grid_range_param_syncing then return end
    scan_start = clamp(x / 100, 0, 1)
    if scan_start > scan_end then
      scan_end = scan_start
      params:set("scan_end", math.floor(scan_end * 100 + 0.5))
    end
    keep_scan_in_range()
    reset_smooth_random()
    redraw()
  end)

  params:add_number("scan_end", "End", 0, 100, math.floor(scan_end * 100 + 0.5), percent_string)
  params:set_action("scan_end", function(x)
    if grid_range_param_syncing then return end
    scan_end = clamp(x / 100, 0, 1)
    if scan_end < scan_start then
      scan_start = scan_end
      params:set("scan_start", math.floor(scan_start * 100 + 0.5))
    end
    keep_scan_in_range()
    reset_smooth_random()
    redraw()
  end)

  params:add_binary("auto_scan", "Auto Scan", "toggle", auto_scan and 1 or 0)
  params:set_action("auto_scan", function(x)
    auto_scan = (x == 1)
    if auto_scan then
      keep_scan_in_range()
      step_elapsed = 0
      ping_dir = 1
      reset_smooth_random()
    end
    redraw()
  end)

  -- LOOPS
  for i = 1, NUM_LOOPS do
    params:add_separator("sg_loop_" .. i, "LOOP " .. i)

    params:add_number("loop_" .. i .. "_pan", "Pan", -100, 100,
      math.floor(loop_pan[i] * 100 + 0.5), signed_percent_string)
    params:set_action("loop_" .. i .. "_pan", function(x)
      loop_pan[i] = clamp(x / 100, -1, 1)
      softcut.pan(i, loop_pan[i])
      apply_scanner()
      redraw()
    end)

    params:add_number("loop_" .. i .. "_pitch", "Pitch", -12, 12,
      loop_semitones[i], semitone_string)
    params:set_action("loop_" .. i .. "_pitch", function(x)
      set_loop_pitch(i, x)
      redraw()
    end)

    params:add_option("loop_" .. i .. "_play_mode", "Play Mode", PLAY_MODE_NAMES, loop_play_mode[i])
    params:set_action("loop_" .. i .. "_play_mode", function(x)
      set_loop_play_mode(i, x, false)
      redraw()
    end)

    params:add_number("loop_" .. i .. "_level", "Level", 0, 150,
      math.floor(loop_level[i] * 100 + 0.5), percent_string)
    params:set_action("loop_" .. i .. "_level", function(x)
      loop_level[i] = clamp(x / 100, 0, 1.5)
      apply_scanner()
      redraw()
    end)

    params:add_number("loop_" .. i .. "_trim_start_ms", "Trim Start", 0, math.floor(MAX_REC * 1000), 0, trim_ms_string)
    params:set_action("loop_" .. i .. "_trim_start_ms", function(x)
      if trim_param_syncing then return end
      if not loaded[i] then
        trim_start[i] = x / 1000
        return
      end

      if trim_window_locked[i] then
        local span = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])
        trim_edit_start[i] = clamp(x / 1000, 0, math.max(0, loop_len[i] - span))
        trim_edit_end[i] = trim_edit_start[i] + span
        if zero_cross_mode == 1 then
          request_zero_cross(i, trim_edit_start[i], "start_locked", span)
        else
          apply_free_trim(i, trim_edit_start[i], "start_locked", span)
        end
      else
        trim_edit_start[i] = clamp(x / 1000, 0, math.max(0, trim_end[i] - MIN_TRIM_LEN))
        if zero_cross_mode == 1 then
          request_zero_cross(i, trim_edit_start[i], "start_unlocked")
        else
          apply_free_trim(i, trim_edit_start[i], "start_unlocked")
        end
      end
    end)

    params:add_number("loop_" .. i .. "_trim_end_ms", "Trim End", 0, math.floor(MAX_REC * 1000),
      math.floor(loop_len[i] * 1000 + 0.5), trim_ms_string)
    params:set_action("loop_" .. i .. "_trim_end_ms", function(x)
      if trim_param_syncing then return end
      if not loaded[i] then
        trim_end[i] = x / 1000
        return
      end

      trim_edit_end[i] = clamp(x / 1000, trim_start[i] + MIN_TRIM_LEN, loop_len[i])
      if zero_cross_mode == 1 then
        request_zero_cross(i, trim_edit_end[i], "end")
      else
        apply_free_trim(i, trim_edit_end[i], "end")
      end
    end)

    params:add_trigger("loop_" .. i .. "_play", "Play / Stop")
    params:set_action("loop_" .. i .. "_play", function()
      toggle_play(i)
    end)

    params:add_trigger("loop_" .. i .. "_record", "Record / Stop")
    params:set_action("loop_" .. i .. "_record", function()
      if recording == i then
        finish_recording()
      elseif recording == 0 then
        start_recording(i)
      else
        finish_recording()
        start_recording(i)
      end
    end)
  end

  -- DELAY
  params:add_separator("sg_delay", "STEREO DELAY")

    params:add_number("delay_time", "Time", 30, 2000, math.floor(delay_time_ms + 0.5),
    function(p) return string.format("%d ms", p:get()) end)
  params:set_action("delay_time", function(x)
    delay_time_ms = clamp(x, 30, 2000)
    apply_delay_params()
    redraw()
  end)

  params:add_number("delay_feedback", "Feedback", 0, 92, math.floor(delay_feedback * 100 + 0.5), percent_string)
  params:set_action("delay_feedback", function(x)
    delay_feedback = clamp(x / 100, 0, 0.92)
    apply_delay_params()
    redraw()
  end)

  params:add_number("delay_mix", "Mix", 0, 100, math.floor(delay_mix * 100 + 0.5), percent_string)
  params:set_action("delay_mix", function(x)
    delay_mix = clamp(x / 100, 0, 1)
    apply_delay_params()
    apply_scanner()
    redraw()
  end)

  params:add_number("delay_tone", "Tone", -100, 100, math.floor(delay_tone + 0.5),
    function(p) return string.format("%+d", p:get()) end)
  params:set_action("delay_tone", function(x)
    delay_tone = clamp(x, -100, 100)
    apply_delay_params()
    redraw()
  end)

  params:add_number("delay_wow", "Wow", 0, 100, math.floor(delay_wow * 100 + 0.5), percent_string)
  params:set_action("delay_wow", function(x)
    delay_wow = clamp(x / 100, 0, 1)
    redraw()
  end)

  params:add_number("delay_flutter", "Flutter", 0, 100, math.floor(delay_flutter * 100 + 0.5), percent_string)
  params:set_action("delay_flutter", function(x)
    delay_flutter = clamp(x / 100, 0, 1)
    redraw()
  end)

  params:add_number("delay_spread", "Spread", 0, 100, math.floor(delay_spread * 100 + 0.5), percent_string)
  params:set_action("delay_spread", function(x)
    delay_spread = clamp(x / 100, 0, 1)
    apply_delay_params()
    redraw()
  end)

  params:add_number("delay_pingpong", "Ping Pong", 0, 100, math.floor(delay_pingpong * 100 + 0.5), percent_string)
  params:set_action("delay_pingpong", function(x)
    delay_pingpong = clamp(x / 100, 0, 1)
    apply_delay_params()
    redraw()
  end)

  params:add_number("delay_width", "Stereo Width", 0, 100, math.floor(delay_width * 100 + 0.5), percent_string)
  params:set_action("delay_width", function(x)
    delay_width = clamp(x / 100, 0, 1)
    apply_delay_params()
    redraw()
  end)
end

local function update_scanner()
  local now = util.time()
  local dt = now - last_tick
  last_tick = now
  dt = clamp(dt, 0, 0.10)

  if scan_range_slew_active then
    scan_range_slew_elapsed = scan_range_slew_elapsed + dt
    local t = clamp(scan_range_slew_elapsed / SCAN_RANGE_SLEW_TIME, 0, 1)
    local eased = t * t * (3 - 2 * t)
    scan_pos = scan_range_slew_from + (scan_range_slew_to - scan_range_slew_from) * eased

    if t >= 1 then
      scan_pos = scan_range_slew_to
      scan_range_slew_active = false
      if auto_scan then
        reset_smooth_random()
      end
    end

  elseif auto_scan then
    local span = range_span()

    if span < 0.0001 then
      scan_pos = scan_start

    elseif scan_mode == 1 then -- forward
      scan_pos = scan_pos + scan_rate * span * dt
      if scan_pos > scan_end then
        scan_pos = scan_start + (scan_pos - scan_end)
      end

    elseif scan_mode == 2 then -- reverse
      scan_pos = scan_pos - scan_rate * span * dt
      if scan_pos < scan_start then
        scan_pos = scan_end - (scan_start - scan_pos)
      end

    elseif scan_mode == 3 then -- ping pong
      scan_pos = scan_pos + ping_dir * scan_rate * span * dt
      if scan_pos >= scan_end then
        scan_pos = scan_end
        ping_dir = -1
      elseif scan_pos <= scan_start then
        scan_pos = scan_start
        ping_dir = 1
      end

    elseif scan_mode == 4 then -- stepped random position
      step_elapsed = step_elapsed + dt
      local interval = 1.0 / math.max(scan_rate, 0.005)
      if step_elapsed >= interval then
        step_elapsed = step_elapsed - interval
        choose_random_target()
        scan_pos = random_target
      end

    elseif scan_mode == 5 then -- smooth random position
      random_elapsed = random_elapsed + dt
      local t = clamp(random_elapsed / random_duration, 0, 1)
      -- cosine ease gives organic acceleration/deceleration
      local eased = 0.5 - 0.5 * math.cos(math.pi * t)
      scan_pos = random_from + (random_target - random_from) * eased
      if t >= 1 then
        random_from = random_target
        choose_random_target()
        random_elapsed = 0
        -- Slightly vary each journey while preserving Rate as the main speed.
        random_duration = math.max(0.05, (1.0 / math.max(scan_rate, 0.005)) * (0.65 + math.random() * 0.70))
      end
    end
  end

  update_delay_mod(now)
  apply_scanner()
  redraw()
end

local function draw_header(title, title_level)
  screen.level(title_level or 15)
  screen.font_size(8)
  screen.move(2, 11)
  screen.text(title)
end

local function draw_page_overlay()
  screen.clear()
  screen.font_size(8)
  screen.level(10)
  screen.move(4, 11)
  screen.text("PAGES")

  for i = 1, #PAGE_NAMES do
    local y = 19 + (i - 1) * 9
    screen.level(i == page and 15 or 4)
    screen.move(8, y)
    screen.text((i == page and "> " or "  ") .. PAGE_NAMES[i])
  end

  screen.level(3)
  screen.move(126, 62)
  screen.text_right("K1+E1")
  screen.update()
end

local function draw_garden()
  draw_header("SYNTHETIC GARDEN", 10)

  local x0, x1 = 5, 123
  local y_base = 43
  local y_peak = 21
  local graph_w = x1 - x0

  -- Map the entire 0-100% Width control directly to the drawable triangle
  -- width. This keeps every displayed triangle identical while ensuring the
  -- graphic starts changing immediately when Width is turned down from 100%.
  -- Scanner/audio width math is unchanged.
  local visual_half_width = 0.025 + (scan_width * 0.175)

  -- baseline / silence-to-silence field
  screen.level(2)
  screen.move(x0, y_base)
  screen.line(x1, y_base)
  screen.stroke()

  -- four triangular scan windows.
  -- Brightness reflects ONLY the scanner's position/weight, independent of
  -- loop level and temporary playback-direction crossfades.
  local visual_weights = scanner_weights(scan_pos)

  local triangle_levels = {}

  for i = 1, NUM_LOOPS do
    local center = loop_center(i)
    local left = center - visual_half_width
    local right = center + visual_half_width
    local cx = math.floor(x0 + center * graph_w + 0.5)
    local lx = math.floor(x0 + left * graph_w + 0.5)
    local rx = math.floor(x0 + right * graph_w + 0.5)
    local lvl = loaded[i] and math.floor(4 + visual_weights[i] * 11) or 2
    triangle_levels[i] = clamp(lvl, 1, 15)

    screen.level(triangle_levels[i])
    screen.move(lx, y_base)
    screen.line(cx, y_peak)
    screen.line(rx, y_base)
    screen.stroke()

    screen.font_size(8)
    screen.move(cx, 52)
    screen.text_center(tostring(i))
  end

  -- Redraw a tiny identical apex on top of each triangle after all overlapping
  -- slopes have been drawn. This keeps tracks 2 and 3 just as sharply pointed
  -- as tracks 1 and 4.
  for i = 1, NUM_LOOPS do
    local center = loop_center(i)
    local cx = math.floor(x0 + center * graph_w + 0.5)

    screen.level(triangle_levels[i])
    screen.move(cx - 1, y_peak + 1)
    screen.line(cx, y_peak)
    screen.line(cx + 1, y_peak + 1)
    screen.stroke()
  end

  -- start/end markers
  local sx = x0 + scan_start * graph_w
  local ex = x0 + scan_end * graph_w
  screen.level(6)
  screen.move(sx, 23)
  screen.line(sx, 45)
  screen.stroke()
  screen.move(ex, 23)
  screen.line(ex, 45)
  screen.stroke()
  screen.font_size(7)
  screen.move(sx, 22)
  screen.text_center("S")
  screen.move(ex, 22)
  screen.text_center("E")

  -- current scan cursor
  local px = x0 + scan_pos * graph_w
  screen.level(15)
  screen.move(px, 22)
  screen.line(px, 45)
  screen.stroke()


  screen.font_size(7)
  screen.level(8)
  screen.move(2, 61)
  screen.text(string.format("W %d%%", math.floor(scan_width * 100 + 0.5)))

  screen.move(36, 61)
  screen.text(string.format("%.3gHz", scan_rate))

  screen.move(126, 61)
  if auto_scan then
    screen.text_right(MODE_NAMES[scan_mode])
  else
    screen.text_right("MANUAL")
  end
end

local function draw_range()
  draw_header("RANGE")

  local x0, x1 = 6, 122
  local y = 34
  local w = x1 - x0
  local sx = x0 + scan_start * w
  local ex = x0 + scan_end * w
  local px = x0 + scan_pos * w

  screen.level(3)
  screen.move(x0, y)
  screen.line(x1, y)
  screen.stroke()

  for i = 1, NUM_LOOPS do
    local x = x0 + loop_center(i) * w
    screen.level(5)
    screen.move(x, y - 4)
    screen.line(x, y + 4)
    screen.stroke()
    screen.font_size(7)
    screen.move(x, y + 13)
    screen.text_center(tostring(i))
  end

  screen.level(10)
  screen.move(sx, y - 12)
  screen.line(sx, y + 7)
  screen.stroke()
  screen.move(ex, y - 12)
  screen.line(ex, y + 7)
  screen.stroke()

  screen.level(15)
  screen.move(px, y - 8)
  screen.line(px, y + 4)
  screen.stroke()

  screen.font_size(8)
  screen.level(10)
  screen.move(2, 54)
  screen.text(string.format("START %.2f", scan_start))
  screen.move(126, 54)
  screen.text_right(string.format("END %.2f", scan_end))

  screen.level(8)
  screen.move(64, 62)
  screen.text_center(MODE_NAMES[scan_mode])
end

local function draw_loops(record_page)
  draw_header(record_page and "RECORD" or "LOOPS")

  for i = 1, NUM_LOOPS do
    local y = 20 + (i - 1) * 10
    screen.level(i == selected_loop and 15 or 4)
    screen.move(3, y)
    screen.text((i == selected_loop and ">" or " ") .. i)

    screen.move(18, y)
    if recording == i then
      local elapsed = clamp(util.time() - rec_started, 0, MAX_REC)
      screen.text(string.format("REC %.1fs", elapsed))
    elseif loaded[i] then
      screen.text(string.format("%.2fs", loop_len[i]))
    else
      screen.text("EMPTY")
    end

    screen.move(65, y)
    if loaded[i] then
      screen.text(playing[i] and "PLAY" or "STOP")
    else
      screen.text("----")
    end

    screen.move(88, y)
    screen.text(string.format("%+dst", loop_semitones[i]))

    -- pan mini-bar
    screen.level(i == selected_loop and 10 or 3)
    screen.move(108, y - 2)
    screen.line(126, y - 2)
    screen.stroke()
    local pan_x = 117 + loop_pan[i] * 9
    screen.level(i == selected_loop and 15 or 5)
    screen.pixel(math.floor(pan_x), y - 2)
    screen.fill()
  end

  screen.font_size(7)
  screen.level(7)
  screen.move(2, 62)
  if record_page then
    if recording == selected_loop then
      screen.text("K2 STOP  E3 PITCH")
    else
      screen.text("K2 REC  E3 PITCH")
      screen.move(126, 62)

      if loaded[selected_loop] then
        screen.text_right(playing[selected_loop] and "K3 STOP" or "K3 PLAY")
      elseif recording == 0 then
        screen.text_right("K3 FILE")
      end
    end
  else
    screen.text("K2 DIR")
    screen.move(126, 62)
    screen.text_right("K3 PLAY/STOP")
  end
end


local function draw_trim()
  draw_header("TRIM")

  screen.font_size(8)
  screen.level(12)
  screen.move(4, 19)
  if loaded[selected_loop] then
    screen.text("LOOP " .. selected_loop .. "  " .. PLAY_MODE_ICONS[loop_play_mode[selected_loop]])
  else
    screen.text("LOOP " .. selected_loop)
  end

  screen.level(7)
  screen.move(124, 19)
  local trim_mode_short = trim_behavior_mode == 1 and "BOUND" or "CHASE"
  screen.text_right(trim_mode_short .. " " .. ZERO_CROSS_MODE_NAMES[zero_cross_mode])

  if not loaded[selected_loop] then
    screen.level(5)
    screen.move(64, 34)
    if recording == selected_loop then
      local elapsed = clamp(util.time() - rec_started, 0, MAX_REC)
      screen.text_center(string.format("REC %.1fs", elapsed))
    else
      screen.text_center("EMPTY")
    end

    screen.font_size(7)
    screen.level(6)
    screen.move(2, 62)
    screen.text("E1 TRK")

    if recording == selected_loop then
      screen.move(126, 62)
      screen.text_right("K3 STOP")
    else
      screen.move(64, 62)
      screen.text_center("K2 PST")
      screen.move(126, 62)
      screen.text_right("K3 REC")
    end
    return
  end

  local i = selected_loop
  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  local x0, x1 = 6, 122
  local center_y = 32
  local wave_h = 8
  local w = x1 - x0
  local sx = x0 + (trim_start[i] / len) * w
  local ex = x0 + (trim_end[i] / len) * w

  local wave = waveform_samples[i]

  -- Draw a dense editor-style waveform. Softcut renders more source samples
  -- than the OLED has horizontal pixels; each screen column displays the
  -- strongest absolute sample found in its source-sample group.
  --
  -- GRAPHICS ONLY: normalize the waveform display to the loudest rendered
  -- peak so quiet and loud recordings are equally readable. The audio buffer,
  -- playback gain, recording level, and scanner levels are never changed.
  if wave ~= nil and #wave > 0 then
    local count = #wave
    local columns = math.floor(w) + 1

    local wave_peak = 0
    for n = 1, count do
      local amp = math.abs(clamp(wave[n] or 0, -1, 1))
      if amp > wave_peak then wave_peak = amp end
    end

    -- Leave a little vertical headroom so the tallest displayed peaks remain
    -- clean and don't visually pin against the top/bottom of the waveform area.
    local display_scale = wave_peak > 0.000001 and (0.90 / wave_peak) or 1

    -- Subtle zero line helps the centered waveform read clearly.
    screen.level(2)
    screen.move(x0, center_y)
    screen.line(x1, center_y)
    screen.stroke()

    for col = 0, columns - 1 do
      local first = math.floor((col * count) / columns) + 1
      local last = math.floor(((col + 1) * count) / columns)
      first = clamp(first, 1, count)
      last = clamp(math.max(first, last), 1, count)

      local column_amp = 0

      for n = first, last do
        local sample = clamp(wave[n] or 0, -1, 1)
        local amp = math.abs(sample)
        if amp > column_amp then column_amp = amp end
      end

      -- Mirror the normalized peak amplitude equally above and below ground.
      local x = x0 + col
      local normalized_amp = clamp(column_amp * display_scale, 0, 0.90)
      local h = math.max(1, math.floor(normalized_amp * wave_h + 0.5))
      local top_y = center_y - h
      local bottom_y = center_y + h

      -- Bright inside the active trim region, dim outside it.
      if x >= sx and x <= ex then
        screen.level(9)
      else
        screen.level(3)
      end

      screen.move(x, top_y)
      screen.line(x, bottom_y)
      screen.stroke()
    end
  else
    -- Temporary baseline while the asynchronous Softcut render arrives.
    screen.level(3)
    screen.move(x0, center_y)
    screen.line(x1, center_y)
    screen.stroke()
  end

  -- Trim start/end handles over the waveform.
  screen.level(15)
  screen.move(sx, center_y - 11)
  screen.line(sx, center_y + 11)
  screen.stroke()
  screen.move(ex, center_y - 11)
  screen.line(ex, center_y + 11)
  screen.stroke()

  -- Live playhead for the selected track.
  -- Phase is cached for all four loop voices; only the selected track is drawn.
  local absolute_pos = loop_playhead_pos[i]
  if absolute_pos ~= nil and absolute_pos > 0 then
    local relative_pos = clamp(absolute_pos - slot_start(i), 0, len)
    local play_x = x0 + (relative_pos / len) * w
    screen.level(15)
    screen.move(play_x, center_y - 8)
    screen.line(play_x, center_y + 8)
    screen.stroke()
  end

  -- Move all readouts upward so the bottom control legend has breathing room.
  screen.font_size(7)
  screen.level(9)
  screen.move(4, 47)
  screen.text(string.format("S %.3fs", trim_start[i]))
  screen.move(124, 47)
  screen.text_right(string.format("E %.3fs", trim_end[i]))

  screen.level(7)
  screen.move(64, 54)
  screen.text_center(string.format("LEN %.3fs", trim_end[i] - trim_start[i]))

  screen.level(6)
  screen.font_size(7)

  -- TRIM footer. Holding K2 replaces the normal controls entirely with
  -- the modifier functions so there is no mixed/ambiguous legend.
  if k2_down and loaded[i] and recording ~= i then
    local k1_action = zero_cross_mode == 1 and "K1H FREE" or "K1H ZX"
    local k3_action = trim_behavior_mode == 1 and "K3 CHASE" or "K3 BOUND"

    screen.move(2, 62)
    screen.text(k1_action)
    screen.move(64, 62)
    screen.text_center("E3 DIREC")
    screen.move(126, 62)
    screen.text_right(k3_action)
  else
    screen.move(2, 62)
    screen.text("E1 TRK")

    if recording == i then
      screen.move(126, 62)
      screen.text_right("K3 STOP")
    elseif loaded[i] then
      screen.move(64, 62)
      screen.text_center("K2 CPY")
      screen.move(126, 62)
      screen.text_right("K3 DEL")
    else
      screen.move(64, 62)
      screen.text_center("K2 PST")
      screen.move(126, 62)
      screen.text_right("K3 REC")
    end
  end
end


local function delay_value_string(bank, param)
  if bank == 1 then
    if param == 1 then
      return string.format("%d ms", math.floor(delay_time_ms + 0.5))
    elseif param == 2 then
      return string.format("%d%%", math.floor(delay_feedback * 100 + 0.5))
    else
      return string.format("%d%%", math.floor(delay_mix * 100 + 0.5))
    end
  elseif bank == 2 then
    if param == 1 then
      return string.format("%+d", math.floor(delay_tone + 0.5))
    elseif param == 2 then
      return string.format("%d%%", math.floor(delay_wow * 100 + 0.5))
    else
      return string.format("%d%%", math.floor(delay_flutter * 100 + 0.5))
    end
  else
    if param == 1 then
      return string.format("%d%%", math.floor(delay_spread * 100 + 0.5))
    elseif param == 2 then
      return string.format("%d%%", math.floor(delay_pingpong * 100 + 0.5))
    else
      return string.format("%d%%", math.floor(delay_width * 100 + 0.5))
    end
  end
end

local function draw_delay()
  draw_header("DELAY")

  screen.font_size(7)
  screen.level(7)
  screen.move(126, 20)
  screen.text_right(DELAY_BANK_NAMES[delay_bank] .. " " .. delay_bank .. "/3")

  -- Restore the cleaner v0.59 parameter layout.
  for i = 1, 3 do
    local y = 29 + (i - 1) * 11
    screen.level(i == delay_param and 15 or 5)
    screen.move(6, y)
    screen.text((i == delay_param and "> " or "  ") .. DELAY_PARAM_NAMES[delay_bank][i])
    screen.move(122, y)
    screen.text_right(delay_value_string(delay_bank, i))
  end

end

local function set_grid_scan_range(x1, x2)
  local low_x = math.min(x1, x2)
  local high_x = math.max(x1, x2)
  local new_start = (low_x - 1) / 15
  local new_end = (high_x - 1) / 15

  scan_start = new_start
  scan_end = new_end

  -- Keep the regular Norns/MIDI parameters synchronized without invoking
  -- their normal immediate-clamp actions.
  grid_range_param_syncing = true
  params:set("scan_start", math.floor(new_start * 100 + 0.5))
  params:set("scan_end", math.floor(new_end * 100 + 0.5))
  grid_range_param_syncing = false

  local target = clamp(scan_pos, scan_start, scan_end)
  if math.abs(target - scan_pos) > 0.000001 then
    scan_range_slew_active = true
    scan_range_slew_from = scan_pos
    scan_range_slew_to = target
    scan_range_slew_elapsed = 0
  else
    scan_range_slew_active = false
  end

  step_elapsed = 0
  ping_dir = 1
  reset_smooth_random()
end

local function grid_rate_for_x(x)
  -- Log spacing keeps the very wide 0.005-10 Hz range musically useful.
  local min_hz = 0.005
  local max_hz = 10.0
  local t = clamp((x - 1) / 15, 0, 1)
  return min_hz * ((max_hz / min_hz) ^ t)
end

local function grid_x_for_rate(rate)
  local min_hz = 0.005
  local max_hz = 10.0
  local r = clamp(rate, min_hz, max_hz)
  local t = math.log(r / min_hz) / math.log(max_hz / min_hz)
  return clamp(math.floor(t * 15 + 0.5) + 1, 1, 16)
end

local function grid_preview_random(step)
  -- Deterministic pseudo-random 0..1 value for LED animation only.
  local v = math.sin((step + 1) * 12.9898 + 78.233) * 43758.5453
  return v - math.floor(v)
end

local function grid_mode_preview_level(mode, selected)
  -- Fixed demo speed, independent of the actual scanner Rate.
  local now = util.time()
  local demo_hz = 0.75
  local phase = (now * demo_hz) % 1
  local value = 0

  if mode == 1 then
    -- Forward: rising ramp.
    value = phase

  elseif mode == 3 then
    -- Ping Pong: triangle.
    value = 1 - math.abs((phase * 2) - 1)

  elseif mode == 2 then
    -- Reverse: falling ramp.
    value = 1 - phase

  elseif mode == 4 then
    -- Step Random: jump and hold.
    local step = math.floor(now * 3)
    value = grid_preview_random(step)

  elseif mode == 5 then
    -- Smooth Random: interpolate smoothly between random targets.
    local speed = 1.5
    local p = now * speed
    local step = math.floor(p)
    local frac = p - step
    local a = grid_preview_random(step)
    local b = grid_preview_random(step + 1)
    local eased = frac * frac * (3 - 2 * frac)
    value = a + (b - a) * eased
  end

  local lo = selected and 5 or 1
  local hi = selected and 15 or 8
  return clamp(math.floor(lo + value * (hi - lo) + 0.5), 1, 15)
end

local function set_grid_trim_range(i, x1, x2)
  if not loaded[i] then return end

  local low_x = math.min(x1, x2)
  local high_x = math.max(x1, x2)
  if low_x == high_x then return end

  selected_loop = i

  local len = math.max(loop_len[i], MIN_TRIM_LEN)
  local new_start = ((low_x - 1) / 15) * len
  local new_end = ((high_x - 1) / 15) * len

  new_start = clamp(new_start, 0, math.max(0, len - MIN_TRIM_LEN))
  new_end = clamp(new_end, new_start + MIN_TRIM_LEN, len)

  trim_edit_start[i] = new_start
  trim_edit_end[i] = new_end

  if zero_cross_mode == 1 then
    -- Snap Start first, then queue End so the existing single-render ZX
    -- pipeline remains deterministic.
    grid_trim_pending_end = {loop = i, target_rel = new_end}
    request_zero_cross(i, new_start, "start_unlocked")
  else
    grid_trim_pending_end = nil
    apply_free_trim(i, new_start, "start_unlocked")
    apply_free_trim(i, new_end, "end")
  end
end

local function grid_redraw()
  if g == nil then return end

  g:all(0)

  -- Bottom-left five keys are direct page selectors.
  -- Dim = available page, bright = currently selected page.
  for x = 1, 5 do
    g:led(x, 8, page == x and 15 or 4)
  end

  -- GARDEN rows:
  -- 1 = range, 2 = live scanner position, 3 = scan width.
  if page == 1 then
    local start_x = math.floor(scan_start * 15 + 0.5) + 1
    local end_x = math.floor(scan_end * 15 + 0.5) + 1
    start_x = clamp(start_x, 1, 16)
    end_x = clamp(end_x, 1, 16)

    for x = start_x, end_x do
      g:led(x, 1, (x == start_x or x == end_x) and 15 or 6)
    end

    -- While the first range key is held, show it immediately as the anchor.
    if grid_range_hold_x ~= nil then
      g:led(grid_range_hold_x, 1, 15)
    end

    -- Rows 2, 3 and 7 use a very dim full-row guide so the available
    -- touch range is always visible, with the current value bright.
    for x = 1, 16 do
      g:led(x, 2, 3)
      g:led(x, 3, 3)
    end

    local scan_x = clamp(math.floor(scan_pos * 15 + 0.5) + 1, 1, 16)
    g:led(scan_x, 2, 15)

    local width_x = clamp(math.floor(scan_width * 15 + 0.5) + 1, 1, 16)
    g:led(width_x, 3, 15)

    local rate_x = grid_x_for_rate(scan_rate)
    for x = 1, 16 do
      g:led(x, 7, x == rate_x and 15 or 3)
    end

    -- Row 8 x11-x15: animated previews of the five selectable scan modes.
    for i = 1, 5 do
      local x = 10 + i
      local mode = grid_scan_mode_map[i]
      g:led(x, 8, grid_mode_preview_level(mode, scan_mode == mode))
    end

    -- Row 8 x16: Auto/Manual status.
    g:led(16, 8, auto_scan and 15 or 3)
  end

  -- RECORD: selected-track editing surface.
  if page == 2 then
    -- Row 1 pitch uses the full 16-button span, with x1=-12, x16=+12,
    -- and x8+x9=0.
    local pitch = clamp(loop_semitones[selected_loop], -12, 12)
    local shown = false

    for x = 1, 16 do
      if grid_pitch_single[x] == pitch then
        g:led(x, 1, 15)
        shown = true
        break
      end
    end

    if not shown then
      for left_x, chord_pitch in pairs(grid_pitch_chord) do
        if chord_pitch == pitch then
          g:led(left_x, 1, 15)
          g:led(left_x + 1, 1, 15)
          break
        end
      end
    end

    -- Row 2 pan: dim full strip, bright current position.
    for x = 1, 16 do
      g:led(x, 2, 3)
    end
    local pan_x = clamp(math.floor(((loop_pan[selected_loop] + 1) * 0.5) * 15 + 0.5) + 1, 1, 16)
    g:led(pan_x, 2, 15)

    -- Row 8 x8-x11: track select.
    for i = 1, NUM_LOOPS do
      g:led(7 + i, 8, selected_loop == i and 15 or 4)
    end

    -- Row 8 x13-x15: Record / Play / Stop.
    g:led(13, 8, recording == selected_loop and 15 or 5)
    g:led(14, 8, (loaded[selected_loop] and playing[selected_loop] and recording ~= selected_loop) and 15 or 5)
    g:led(15, 8, (loaded[selected_loop] and not playing[selected_loop] and recording ~= selected_loop) and 15 or 5)

    -- Row 8 x16: DELETE. A loaded selected loop flashes quickly as a warning.
    g:led(16, 8,
      loaded[selected_loop]
      and ((math.floor(util.time() * 8) % 2 == 0) and 15 or 0)
      or 3
    )
  end

  -- TRIM: rows 1-4 are full-loop timelines for loops 1-4.
  if page == 3 then
    for i = 1, NUM_LOOPS do
      for x = 1, 16 do
        g:led(x, i, 3)
      end

      if loaded[i] then
        local len = math.max(loop_len[i], MIN_TRIM_LEN)
        local sx = clamp(math.floor((trim_start[i] / len) * 15 + 0.5) + 1, 1, 16)
        local ex = clamp(math.floor((trim_end[i] / len) * 15 + 0.5) + 1, 1, 16)

        for x = sx, ex do
          g:led(x, i, (x == sx or x == ex) and 15 or 7)
        end

        -- Each track shows its own live Softcut playhead across the full
        -- recorded loop length. Keep trim endpoints at full brightness.
        local absolute_pos = loop_playhead_pos[i]
        if absolute_pos ~= nil and absolute_pos > 0 then
          local relative_pos = clamp(absolute_pos - slot_start(i), 0, len)
          local play_x = clamp(math.floor((relative_pos / len) * 15 + 0.5) + 1, 1, 16)
          local play_level = (play_x == sx or play_x == ex) and 15 or 12
          g:led(play_x, i, play_level)
        end
      end
    end

    if grid_trim_hold_row ~= nil and grid_trim_hold_x ~= nil then
      g:led(math.abs(grid_trim_hold_x), grid_trim_hold_row, 15)
    end

    -- Row 6: global TRIM behavior controls.
    -- x1 BOUND, x2 CHASE, x4 ZX, x5 FREE.
    g:led(1, 6, trim_behavior_mode == 1 and 15 or 4)
    g:led(2, 6, trim_behavior_mode == 2 and 15 or 4)
    g:led(4, 6, zero_cross_mode == 1 and 15 or 4)
    g:led(5, 6, zero_cross_mode == 2 and 15 or 4)

    -- Row 7 x11-x13: per-track play direction.
    -- Forward / Ping Pong / Reverse animate like the GARDEN motion previews.
    local direction_modes = {1, 3, 2}
    for n = 1, 3 do
      local x = 10 + n
      local mode = direction_modes[n]
      g:led(x, 7, grid_mode_preview_level(
        mode,
        loop_play_mode[selected_loop] == mode
      ))
    end

    -- Row 7 x15/x16: COPY / PASTE.
    g:led(15, 7, clipboard_has_audio and 8 or 4)
    g:led(16, 7, clipboard_has_audio and 8 or 4)

    -- Row 8 x8-x11: track select, matching the RECORD page.
    for i = 1, NUM_LOOPS do
      g:led(7 + i, 8, selected_loop == i and 15 or 4)
    end

    -- Row 8 x13-x15: Record / Play / Stop for the selected loop.
    g:led(13, 8, recording == selected_loop and 15 or 5)
    g:led(14, 8, (loaded[selected_loop] and playing[selected_loop] and recording ~= selected_loop) and 15 or 5)
    g:led(15, 8, (loaded[selected_loop] and not playing[selected_loop] and recording ~= selected_loop) and 15 or 5)

    -- Row 8 x16: DELETE. A loaded selected loop flashes quickly as a warning.
    g:led(16, 8,
      loaded[selected_loop]
      and ((math.floor(util.time() * 8) % 2 == 0) and 15 or 0)
      or 3
    )
  end

  g:refresh()
end

local function grid_key(x, y, z)
  -- Bottom-left five keys remain direct page selectors.
  if y == 8 and x >= 1 and x <= 5 and z == 1 then
    page = x
    k1_down = false
    k2_down = false
    k2_modified = false
    grid_range_hold_x = nil
    grid_pitch_hold_x = nil
    grid_pitch_chord_used = false
    grid_trim_hold_row = nil
    grid_trim_hold_x = nil
    grid_trim_pending_end = nil

    grid_redraw()
    redraw()
    return
  end

  -- GARDEN top row uses a deliberate hold-and-chord gesture only:
  -- hold one position, then press another position to define the full range.
  -- A single tap/release by itself never changes Start or End.
  if page == 1 and y == 1 and x >= 1 and x <= 16 then
    if z == 1 then
      if grid_range_hold_x == nil then
        grid_range_hold_x = x
        grid_redraw()
      elseif x ~= grid_range_hold_x then
        set_grid_scan_range(grid_range_hold_x, x)
        grid_redraw()
        redraw()
      end
    elseif z == 0 and x == grid_range_hold_x then
      grid_range_hold_x = nil
      grid_redraw()
    end
    return
  end

  -- GARDEN row 2: direct 16-position scanner strip.
  -- This intentionally overrides the live scanner position even while Auto
  -- Scan is enabled; Auto Scan then continues from the newly pressed point.
  if page == 1 and y == 2 and x >= 1 and x <= 16 and z == 1 then
    local position = (x - 1) / 15
    scan_pos = position
    params:set("scan_position", math.floor(position * 100 + 0.5))

    if auto_scan then
      step_elapsed = 0
      if scan_mode == 5 then
        reset_smooth_random()
      end
    end

    apply_scanner()
    grid_redraw()
    redraw()
    return
  end

  -- GARDEN row 3: direct 16-step Width selector from 0% to 100%.
  if page == 1 and y == 3 and x >= 1 and x <= 16 and z == 1 then
    local width_percent = math.floor(((x - 1) / 15) * 100 + 0.5)
    params:set("scan_width", width_percent)
    grid_redraw()
    redraw()
    return
  end

  -- GARDEN row 7: logarithmic 16-step scan-rate selector, 0.005-10 Hz.
  if page == 1 and y == 7 and x >= 1 and x <= 16 and z == 1 then
    local hz = grid_rate_for_x(x)
    params:set("scan_rate_mhz", math.floor(hz * 1000 + 0.5))
    grid_redraw()
    redraw()
    return
  end

  -- GARDEN row 8 x11-x15: direct scan-mode selection.
  if page == 1 and y == 8 and x >= 11 and x <= 15 and z == 1 then
    local mode = grid_scan_mode_map[x - 10]
    params:set("scan_mode", mode)
    grid_redraw()
    redraw()
    return
  end

  -- GARDEN row 8 x16: toggle Manual / Auto Scan.
  if page == 1 and y == 8 and x == 16 and z == 1 then
    params:set("auto_scan", auto_scan and 0 or 1)
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 1: full-span pitch selector.
  -- Singles use x1=-12 through x16=+12 anchors; approved adjacent chords
  -- fill the missing semitones, including x8+x9=0.
  if page == 2 and y == 1 and x >= 1 and x <= 16 then
    if z == 1 then
      if grid_pitch_hold_x == nil then
        grid_pitch_hold_x = x
        grid_pitch_chord_used = false
      elseif x ~= grid_pitch_hold_x and math.abs(x - grid_pitch_hold_x) == 1 then
        local left_x = math.min(x, grid_pitch_hold_x)
        local chord_pitch = grid_pitch_chord[left_x]
        if chord_pitch ~= nil then
          params:set("loop_" .. selected_loop .. "_pitch", chord_pitch)
          grid_pitch_chord_used = true
          grid_redraw()
          redraw()
        end
      end
    elseif z == 0 and x == grid_pitch_hold_x then
      if not grid_pitch_chord_used then
        local single_pitch = grid_pitch_single[x]
        if single_pitch ~= nil then
          params:set("loop_" .. selected_loop .. "_pitch", single_pitch)
        end
      end
      grid_pitch_hold_x = nil
      grid_pitch_chord_used = false
      grid_redraw()
      redraw()
    end
    return
  end

  -- RECORD row 2: selected-track pan, x1 hard left to x16 hard right.
  if page == 2 and y == 2 and x >= 1 and x <= 16 and z == 1 then
    local pan_percent = math.floor(-100 + ((x - 1) / 15) * 200 + 0.5)
    params:set("loop_" .. selected_loop .. "_pan", pan_percent)
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 8 x8-x11: select track 1-4.
  if page == 2 and y == 8 and x >= 8 and x <= 11 and z == 1 then
    selected_loop = x - 7
    grid_pitch_hold_x = nil
    grid_pitch_chord_used = false
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 8 x13: Record / Stop-recording-and-play.
  if page == 2 and y == 8 and x == 13 and z == 1 then
    if recording == selected_loop then
      finish_recording()
    else
      params:set("loop_" .. selected_loop .. "_record", 1)
    end
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 8 x14: finish recording and play, or play a stopped loop.
  if page == 2 and y == 8 and x == 14 and z == 1 then
    if recording == selected_loop then
      finish_recording()
    elseif loaded[selected_loop] and not playing[selected_loop] then
      toggle_play(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 8 x15: stop recording or playback on selected track.
  if page == 2 and y == 8 and x == 15 and z == 1 then
    if recording == selected_loop then
      finish_recording()
      if playing[selected_loop] then
        toggle_play(selected_loop)
      end
    elseif loaded[selected_loop] and playing[selected_loop] then
      toggle_play(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end

  -- RECORD row 8 x16: delete the selected recording.
  if page == 2 and y == 8 and x == 16 and z == 1 then
    if loaded[selected_loop] or recording == selected_loop then
      delete_loop(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end

  -- TRIM rows 1-4:
  -- Hold one position and press a second position to define/redefine the loop.
  -- After a loop window is established, a single tap moves that fixed-length
  -- window so the tapped position becomes its new Start.
  if page == 3 and y >= 1 and y <= 4 and x >= 1 and x <= 16 then
    if z == 1 then
      selected_loop = y

      if grid_trim_hold_row == nil then
        grid_trim_hold_row = y
        grid_trim_hold_x = x
        grid_redraw()
        redraw()
      elseif grid_trim_hold_row == y
          and math.abs(grid_trim_hold_x) ~= x then
        set_grid_trim_range(y, math.abs(grid_trim_hold_x), x)

        -- Negative means this hold has used the two-button gesture. Keep the
        -- original Start encoded in the absolute value so more End presses
        -- can continuously redefine the range until Start is released.
        grid_trim_hold_x = -math.abs(grid_trim_hold_x)
        grid_redraw()
        redraw()
      end

    elseif z == 0
        and grid_trim_hold_row == y
        and math.abs(grid_trim_hold_x or 0) == x then

      if grid_trim_hold_x > 0 and loaded[y] and trim_window_locked[y] then
        local len = math.max(loop_len[y], MIN_TRIM_LEN)
        local span = math.max(MIN_TRIM_LEN, trim_end[y] - trim_start[y])
        local max_start = math.max(0, len - span)
        local target_start = clamp(((x - 1) / 15) * len, 0, max_start)

        trim_edit_start[y] = target_start
        trim_edit_end[y] = target_start + span

        if zero_cross_mode == 1 then
          request_zero_cross(y, target_start, "start_locked", span)
        else
          apply_free_trim(y, target_start, "start_locked", span)
        end
      end

      grid_trim_hold_row = nil
      grid_trim_hold_x = nil
      grid_redraw()
      redraw()
    end
    return
  end

  -- TRIM row 8 x8-x11: select track 1-4, matching RECORD.
  if page == 3 and y == 8 and x >= 8 and x <= 11 and z == 1 then
    selected_loop = x - 7
    grid_trim_hold_row = nil
    grid_trim_hold_x = nil

    if loaded[selected_loop] and #waveform_samples[selected_loop] == 0 then
      request_waveform(selected_loop)
    end

    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 6 x1/x2: BOUND / CHASE.
  if page == 3 and y == 6 and x == 1 and z == 1 then
    trim_behavior_mode = 1

    -- Returning to BOUND immediately cancels active chase transport and
    -- restores the exact selected trim boundaries.
    for i = 1, NUM_LOOPS do
      if loop_trim_transit[i] then
        loop_trim_transit[i] = false
        apply_loop_trim(i)
      end
    end

    grid_redraw()
    redraw()
    return
  end

  if page == 3 and y == 6 and x == 2 and z == 1 then
    trim_behavior_mode = 2
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 6 x4/x5: zero-cross snap / free trim.
  if page == 3 and y == 6 and x == 4 and z == 1 then
    zero_cross_mode = 1
    for i = 1, NUM_LOOPS do
      sync_trim_edit_targets(i)
    end
    zero_cross_request_token = zero_cross_request_token + 1
    pending_zero_cross_request = nil
    grid_trim_pending_end = nil
    grid_redraw()
    redraw()
    return
  end

  if page == 3 and y == 6 and x == 5 and z == 1 then
    zero_cross_mode = 2
    for i = 1, NUM_LOOPS do
      sync_trim_edit_targets(i)
    end
    zero_cross_request_token = zero_cross_request_token + 1
    pending_zero_cross_request = nil
    grid_trim_pending_end = nil
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 7 x11-x13: Forward / Ping Pong / Reverse for selected track.
  if page == 3 and y == 7 and x >= 11 and x <= 13 and z == 1 then
    local direction_modes = {1, 3, 2}
    local mode = direction_modes[x - 10]
    params:set("loop_" .. selected_loop .. "_play_mode", mode)
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 7 x15: COPY selected loop.
  if page == 3 and y == 7 and x == 15 and z == 1 then
    copy_loop_to_clipboard(selected_loop)
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 7 x16: PASTE clipboard into selected empty loop.
  if page == 3 and y == 7 and x == 16 and z == 1 then
    paste_clipboard_to_loop(selected_loop)
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 8 x13: Record / Stop-recording-and-play.
  if page == 3 and y == 8 and x == 13 and z == 1 then
    if recording == selected_loop then
      finish_recording()
    else
      params:set("loop_" .. selected_loop .. "_record", 1)
    end
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 8 x14: finish recording and play, or play a stopped loop.
  if page == 3 and y == 8 and x == 14 and z == 1 then
    if recording == selected_loop then
      finish_recording()
    elseif loaded[selected_loop] and not playing[selected_loop] then
      toggle_play(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 8 x15: stop recording or playback.
  if page == 3 and y == 8 and x == 15 and z == 1 then
    if recording == selected_loop then
      finish_recording()
      if playing[selected_loop] then
        toggle_play(selected_loop)
      end
    elseif loaded[selected_loop] and playing[selected_loop] then
      toggle_play(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end

  -- TRIM row 8 x16: delete the selected recording.
  if page == 3 and y == 8 and x == 16 and z == 1 then
    if loaded[selected_loop] or recording == selected_loop then
      delete_loop(selected_loop)
    end
    grid_redraw()
    redraw()
    return
  end
end

function redraw()
  grid_redraw()

  if file_selecting or fileselect.done == false then
    return
  end

  screen.clear()

  if k1_down then
    draw_page_overlay()
    return
  end

  if page == 1 then
    draw_garden()
  elseif page == 2 then
    draw_loops(true)
  elseif page == 3 then
    draw_trim()
  elseif page == 4 then
    draw_range()
  elseif page == 5 then
    draw_delay()
  end

  screen.update()
end

function enc(n, d)
  if k1_down and n == 1 then
    page = clamp(page + (d > 0 and 1 or -1), 1, 5)
    k2_down = false
    k2_modified = false
    redraw()
    return
  end

  if k2_down and page == 3 and n == 3 and d ~= 0 and loaded[selected_loop] then
    k2_modified = true
    local mode = loop_play_mode[selected_loop] + (d > 0 and 1 or -1)
    if mode < 1 then mode = #PLAY_MODE_NAMES end
    if mode > #PLAY_MODE_NAMES then mode = 1 end
    params:set("loop_" .. selected_loop .. "_play_mode", mode)
    redraw()
    return
  end

  if page == 1 then
    if n == 1 then
      if not auto_scan then
        params:delta("scan_position", d)
      end
    elseif n == 2 then
      params:delta("scan_width", d)
    elseif n == 3 then
      -- Progressive rate stepping keeps the slow scanner range precise while
      -- making higher-rate travel practical all the way up to 10 Hz.
      local scan_step_mhz = 5
      if scan_rate >= 5.0 then
        scan_step_mhz = 100
      elseif scan_rate >= 2.0 then
        scan_step_mhz = 50
      elseif scan_rate >= 0.5 then
        scan_step_mhz = 25
      elseif scan_rate >= 0.1 then
        scan_step_mhz = 10
      end
      params:delta("scan_rate_mhz", d * scan_step_mhz)
    end

  elseif page == 2 then -- RECORD
    if n == 1 and d ~= 0 then
      selected_loop = clamp(selected_loop + (d > 0 and 1 or -1), 1, NUM_LOOPS)
    elseif n == 2 then
      params:delta("loop_" .. selected_loop .. "_pan", d * 2)
    elseif n == 3 and d ~= 0 then
      params:delta("loop_" .. selected_loop .. "_pitch", d > 0 and 1 or -1)
    end

  elseif page == 3 then -- TRIM
    if n == 1 and d ~= 0 then
      selected_loop = clamp(selected_loop + (d > 0 and 1 or -1), 1, NUM_LOOPS)
      if loaded[selected_loop] and #waveform_samples[selected_loop] == 0 then
        request_waveform(selected_loop)
      end
    elseif n == 2 and loaded[selected_loop] and d ~= 0 then
      local i = selected_loop
      local direction = d > 0 and 1 or -1
      local move = direction * trim_encoder_step(2)

      if trim_window_locked[i] then
        local span = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])
        local max_start = math.max(0, loop_len[i] - span)
        trim_edit_start[i] = clamp(trim_edit_start[i] + move, 0, max_start)
        trim_edit_end[i] = trim_edit_start[i] + span

        if zero_cross_mode == 1 then
          request_zero_cross(i, trim_edit_start[i], "start_locked", span)
        else
          apply_free_trim(i, trim_edit_start[i], "start_locked", span)
        end
      else
        local max_start = math.max(0, trim_end[i] - MIN_TRIM_LEN)
        trim_edit_start[i] = clamp(trim_edit_start[i] + move, 0, max_start)

        if zero_cross_mode == 1 then
          request_zero_cross(i, trim_edit_start[i], "start_unlocked")
        else
          apply_free_trim(i, trim_edit_start[i], "start_unlocked")
        end
      end

    elseif n == 3 and loaded[selected_loop] and d ~= 0 then
      local i = selected_loop
      local direction = d > 0 and 1 or -1
      local move = direction * trim_encoder_step(3)

      trim_edit_end[i] = clamp(
        trim_edit_end[i] + move,
        trim_start[i] + MIN_TRIM_LEN,
        loop_len[i]
      )

      if zero_cross_mode == 1 then
        request_zero_cross(i, trim_edit_end[i], "end")
      else
        apply_free_trim(i, trim_edit_end[i], "end")
      end
    end

  elseif page == 4 then -- RANGE
    if n == 1 and d ~= 0 then
      params:delta("scan_mode", d > 0 and 1 or -1)
    elseif n == 2 then
      params:delta("scan_start", d)
    elseif n == 3 then
      params:delta("scan_end", d)
    end

  elseif page == 5 then -- DELAY
    if n == 1 and d ~= 0 then
      delay_bank = delay_bank + (d > 0 and 1 or -1)
      if delay_bank < 1 then delay_bank = 3 end
      if delay_bank > 3 then delay_bank = 1 end

    elseif n == 2 and d ~= 0 then
      delay_param = clamp(delay_param + (d > 0 and 1 or -1), 1, 3)

    elseif n == 3 then
      local ids = {
        {"delay_time", "delay_feedback", "delay_mix"},
        {"delay_tone", "delay_wow", "delay_flutter"},
        {"delay_spread", "delay_pingpong", "delay_width"}
      }
      local steps = {
        {10, 1, 1},
        {2, 1, 1},
        {1, 1, 1}
      }
      params:delta(ids[delay_bank][delay_param], d * steps[delay_bank][delay_param])
    end
  end

  apply_scanner()
  redraw()
end

function key(n, z)
  -- TRIM shortcut: hold K2 + press K1 to toggle ZERO X / FREE.
  -- Intercept this before K1 opens the page selector.
  if page == 3 and n == 1 and z == 1 and k2_down then
    k2_modified = true
    zero_cross_mode = zero_cross_mode == 1 and 2 or 1
    k1_down = false
    for i = 1, NUM_LOOPS do
      sync_trim_edit_targets(i)
    end

    -- Cancel any outstanding zero-cross render so switching to FREE cannot
    -- apply a stale snap result afterward.
    zero_cross_request_token = zero_cross_request_token + 1
    pending_zero_cross_request = nil

    redraw()
    return
  end

  if n == 1 then
    k1_down = (z == 1)
    redraw()
    return
  end

  if page == 1 then
    if n == 2 and z == 1 then
      params:set("auto_scan", auto_scan and 0 or 1)
    elseif n == 3 and z == 1 then
      local next_mode = scan_mode + 1
      if next_mode > #MODE_NAMES then next_mode = 1 end
      params:set("scan_mode", next_mode)
    end

  elseif page == 2 then -- RECORD
    if n == 2 and z == 1 then
      -- K2 is the dedicated record transport:
      -- REC on an idle track, STOP while that track is actively recording.
      params:set("loop_" .. selected_loop .. "_record", 1)

    elseif n == 3 and z == 1 then
      -- K3 never stops an active recording. Once audio exists it becomes
      -- the playback transport: STOP while playing, PLAY while stopped.
      if recording == selected_loop then
        return
      elseif loaded[selected_loop] then
        toggle_play(selected_loop)
      elseif recording == 0 then
        choose_audio_file(selected_loop)
        return
      end
    end

  elseif page == 3 then -- TRIM
    if n == 2 then
      if z == 1 then
        k2_down = true
        k2_modified = false
        redraw()
        return
      else
        local was_modified = k2_modified
        k2_down = false
        k2_modified = false

        if not was_modified and recording ~= selected_loop then
          if loaded[selected_loop] then
            copy_loop_to_clipboard(selected_loop)
          else
            paste_clipboard_to_loop(selected_loop)
          end
        end

        redraw()
        return
      end
    end

    if n == 3 and z == 1 and k2_down then
      k2_modified = true
      trim_behavior_mode = trim_behavior_mode == 1 and 2 or 1

      if trim_behavior_mode == 1 then
        -- Returning to BOUND immediately cancels any catch-up transport and
        -- restores the exact selected trim points on every loop.
        for i = 1, NUM_LOOPS do
          if loop_trim_transit[i] then
            loop_trim_transit[i] = false
            apply_loop_trim(i)
          end
        end
      end

      redraw()
      return
    end

    if z == 1 then
      if recording == selected_loop then
        if n == 3 then
          finish_recording()
        end
      elseif loaded[selected_loop] then
        if n == 3 then
          delete_loop(selected_loop)
        end
      else
        if n == 3 then
          start_recording(selected_loop)
        end
      end
    end

  end

  redraw()
end


local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function preset_state_dir(number)
  return norns.state.data .. "/" .. tostring(number)
end

local function preset_audio_dir(number)
  return _path.audio .. "Synthetic Garden/PSET " .. tostring(number)
end

local function ensure_dir(dir)
  os.execute("mkdir -p " .. string.format("%q", dir))
end

local function save_preset_audio(number)
  local state_dir = preset_state_dir(number)
  local audio_dir = preset_audio_dir(number)

  ensure_dir(state_dir)
  ensure_dir(audio_dir)

  local state = {
    loaded = {},
    playing = {},
    loop_len = {},
    loop_file = {},
    trim_start = {},
    trim_end = {},
    trim_window_locked = {},
    play_mode = {},
    trim_behavior_mode = trim_behavior_mode,
    zero_cross_mode = zero_cross_mode
  }

  for i = 1, NUM_LOOPS do
    state.loaded[i] = loaded[i]
    state.playing[i] = playing[i]
    state.loop_len[i] = loop_len[i]
    state.loop_file[i] = loop_file[i]
    state.trim_start[i] = trim_start[i]
    state.trim_end[i] = trim_end[i]
    state.trim_window_locked[i] = trim_window_locked[i]
    state.play_mode[i] = loop_play_mode[i]

    local wav = audio_dir .. "/loop-" .. i .. ".wav"

    if loaded[i] and loop_len[i] > 0 then
      -- Save the actual Softcut buffer region at its original recorded pitch.
      softcut.buffer_write_mono(wav, slot_start(i), loop_len[i], 1)
    else
      os.remove(wav)
    end
  end

  tab.save(state, state_dir .. "/loops.data")
  print("Synthetic Garden: saved loop audio for PSET " .. tostring(number))
end

local function restore_preset_audio(number)
  local state_dir = preset_state_dir(number)
  local audio_dir = preset_audio_dir(number)
  local state_path = state_dir .. "/loops.data"

  if not file_exists(state_path) then
    print("Synthetic Garden: no saved loop audio for PSET " .. tostring(number))
    return
  end

  local state = tab.load(state_path)
  if state == nil then
    print("Synthetic Garden: could not load loop state for PSET " .. tostring(number))
    return
  end

  if recording ~= 0 then
    finish_recording()
  end

  trim_behavior_mode = state.trim_behavior_mode or 1
  trim_behavior_mode = clamp(trim_behavior_mode, 1, #TRIM_MODE_NAMES)
  zero_cross_mode = state.zero_cross_mode or 1
  zero_cross_mode = clamp(zero_cross_mode, 1, #ZERO_CROSS_MODE_NAMES)

  for i = 1, NUM_LOOPS do
    local start = slot_start(i)
    local wav = audio_dir .. "/loop-" .. i .. ".wav"
    loop_trim_transit[i] = false

    softcut.buffer_clear_region_channel(1, start, MAX_REC, 0.02, 0)

    loaded[i] = state.loaded and state.loaded[i] or false
    playing[i] = state.playing and state.playing[i] or true
    loop_len[i] = state.loop_len and state.loop_len[i] or MAX_REC
    loop_file[i] = state.loop_file and state.loop_file[i] or ""
    trim_start[i] = state.trim_start and state.trim_start[i] or 0
    trim_end[i] = state.trim_end and state.trim_end[i] or loop_len[i]
    sync_trim_edit_targets(i)
    trim_window_locked[i] = state.trim_window_locked and state.trim_window_locked[i] or false
    loop_play_mode[i] = state.play_mode and state.play_mode[i] or loop_play_mode[i] or 1
    loop_ping_dir[i] = (loop_play_mode[i] == 2) and -1 or 1
    normalize_trim(i)
    sync_trim_params(i)
    refresh_loop_rate(i)

    if loaded[i] and file_exists(wav) then
      local duration = clamp(loop_len[i], 0.10, MAX_REC)
      local active_len = math.max(MIN_TRIM_LEN, trim_end[i] - trim_start[i])

      softcut.buffer_read_mono(wav, 0, start, duration, 1, 1, 0, 1)
      softcut.fade_time(i, math.min(LOOP_EDGE_FADE, active_len * 0.10))
      softcut.loop_start(i, start + trim_start[i])
      softcut.loop_end(i, start + trim_end[i])
      local restore_pos = start + (loop_rate[i] < 0 and trim_end[i] - 0.001 or trim_start[i])
      softcut.position(i, restore_pos)
      loop_playhead_pos[i] = restore_pos
      softcut.rate(i, loop_rate[i])
      softcut.play(i, playing[i] and 1 or 0)
      request_waveform(i)
    else
      loaded[i] = false
      playing[i] = false
      softcut.play(i, 0)
    end
  end

  apply_delay_params()
  apply_scanner()
  redraw()
  print("Synthetic Garden: restored loop audio for PSET " .. tostring(number))
end

local function delete_preset_audio(number)
  local state_dir = preset_state_dir(number)
  local audio_dir = preset_audio_dir(number)

  os.execute("rm -rf " .. string.format("%q", state_dir))
  os.execute("rm -rf " .. string.format("%q", audio_dir))

  print("Synthetic Garden: deleted loop audio for PSET " .. tostring(number))
end

local function setup_preset_callbacks()
  params.action_write = function(filename, name, number)
    save_preset_audio(number)
  end

  params.action_read = function(filename, silent, number)
    restore_preset_audio(number)
  end

  params.action_delete = function(filename, name, number)
    delete_preset_audio(number)
  end
end

function init()
  math.randomseed(os.time())
  fileselect.done = true
  file_selecting = false

  -- Connect an attached Monome-compatible Grid 128.
  g = grid.connect()
  if g ~= nil then
    g.key = grid_key
    grid_redraw()
  end

  -- Softcut uses one mono buffer divided into four independent thirty-second slots.
  softcut.buffer_clear()
  audio.level_adc_cut(1)
  softcut.event_render(on_waveform_render)

  for i = 1, NUM_LOOPS do
    local start = slot_start(i)

    softcut.enable(i, 1)
    softcut.buffer(i, 1)
    softcut.level(i, 0)
    softcut.pan(i, loop_pan[i])
    softcut.level_slew_time(i, 0.03)
    softcut.rate_slew_time(i, PITCH_RATE_SLEW)
    softcut.fade_time(i, LOOP_EDGE_FADE)

    softcut.loop(i, 1)
    softcut.loop_start(i, start)
    softcut.loop_end(i, start + MAX_REC)
    softcut.position(i, start)
    softcut.rate(i, 1)
    softcut.play(i, 1)

    softcut.rec(i, 0)
    softcut.rec_level(i, 0)
    softcut.pre_level(i, 1)

    -- Sum stereo input to mono at conservative gain.
    softcut.level_input_cut(1, i, 0.8)
    softcut.level_input_cut(2, i, 0.8)
    softcut.phase_quant(i, PHASE_QUANT)
  end

  softcut.event_phase(on_loop_phase)
  softcut.poll_start_phase()

  -- Two always-running mono delay lines in Softcut buffer 2.
  for _, v in ipairs({DELAY_VL, DELAY_VR}) do
    softcut.enable(v, 1)
    softcut.buffer(v, 2)
    softcut.level(v, 0)
    softcut.level_slew_time(v, 0.04)
    softcut.recpre_slew_time(v, 0.06)
    softcut.rate_slew_time(v, 0.08)
    softcut.fade_time(v, 0.008)
    softcut.loop(v, 1)
    softcut.rate(v, 1)
    softcut.play(v, 1)
    softcut.rec(v, 1)
    softcut.rec_level(v, 1)
    softcut.pre_level(v, delay_feedback)
    softcut.level_input_cut(1, v, 0)
    softcut.level_input_cut(2, v, 0)
  end

  softcut.loop_start(DELAY_VL, DELAY_L_START)
  softcut.loop_end(DELAY_VL, DELAY_L_START + delay_time_ms / 1000)
  softcut.position(DELAY_VL, DELAY_L_START)

  softcut.loop_start(DELAY_VR, DELAY_R_START)
  softcut.loop_end(DELAY_VR, DELAY_R_START + delay_time_ms / 1000)
  softcut.position(DELAY_VR, DELAY_R_START)

  apply_delay_params()

  setup_mappable_params()
  setup_preset_callbacks()

  scan_pos = scan_start
  reset_smooth_random()
  last_tick = util.time()

  scan_metro = metro.init()
  scan_metro.time = 1 / 30
  scan_metro.event = update_scanner
  scan_metro:start()

  redraw()
end

function cleanup()
  if g ~= nil then
    g:all(0)
    g:refresh()
  end

  zero_cross_request_token = zero_cross_request_token + 1
  pending_zero_cross_request = nil
  stop_record_clock()
  for i = 1, NUM_LOOPS do
    loop_direction_token[i] = loop_direction_token[i] + 1
    loop_direction_busy[i] = false
    loop_trim_transit[i] = false
  end
  softcut.poll_stop_phase()
  if scan_metro ~= nil then
    scan_metro:stop()
  end
  for i = 1, 6 do
    softcut.rec(i, 0)
    softcut.play(i, 0)
    softcut.level(i, 0)
  end
end
