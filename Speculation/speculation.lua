-- speculation
-- polyphonic granular synth
-- modeled on the GR-1's
-- feature set (clean-room)
--
-- home: sample + grains
-- E1 opens menu (5s idle: home)
-- E1 page / E2 select / E3 adjust
-- K1 hold: E2 position, E3 scan
-- K2 tap: record
-- K2 hold: load sample
-- K3 drone
-- K1+K2 seq menu, K1+K3 seq play
--
-- grid 128: linnstrument-style
-- keyboard (rows = 4ths)
--
-- load a sample:
-- PARAMS > sample

engine.name = "Grainery"

local musicutil = require "musicutil"

local SRC = {"none", "lfo1", "lfo2", "amp env", "filt env", "velocity",
  "modwheel", "aftertouch", "cv1", "cv2", "keytrack", "random"}
local DST = {"none", "position", "scan", "spray", "size", "density",
  "pitch", "pitch spray", "cutoff", "resonance", "pan", "amp", "spawn rand"}
local MATRIX_DEFAULTS = { -- {src, dst, amt}: all slots start empty
  {1, 1, 0}, {1, 1, 0}, {1, 1, 0}, {1, 1, 0},
  {1, 1, 0}, {1, 1, 0}, {1, 1, 0}, {1, 1, 0},
}
local CHORDS = {
  {"unison", {0}}, {"octaves", {0, 12}}, {"fifth", {0, 7}}, {"5th+oct", {0, 7, 12}},
  {"major", {0, 4, 7, 12}}, {"minor", {0, 3, 7, 12}}, {"sus4", {0, 5, 7, 12}},
  {"maj7", {0, 4, 7, 11}}, {"min7", {0, 3, 7, 10}},
}
local ZONES = {"A", "B", "C"}

local pages = {}
local page = 1
local sel = {}
local alt = false
local waveform, wave_peak = nil, 1
local playheads = {}
local recording = false
local held, sustained, sustain = {}, {}, false
local drone_ids = {}
local next_id = 0
local m
local redraw_metro
local grains = {}      -- visual grains
local MAX_GRAINS = 64
local show_notice -- defined with the screen code below
local view = "home"     -- "home" (sample + grains), "menu", "browse" or "seq"
local last_touch = 0
local MENU_TIMEOUT = 5  -- seconds of no input before returning home
local K2_HOLD = 0.5     -- seconds K2 must be held to open the browser
local k2_clock = nil

-- ---------- helpers ----------

local function pct(p) return string.format("%.0f%%", p:get() * 100) end
local function bip(p) return string.format("%+.2f", p:get()) end
local function secs(p)
  local v = p:get()
  if v < 1 then return string.format("%.0f ms", v * 1000) end
  return string.format("%.2f s", v)
end
local function note_fmt(p)
  local v = p:get()
  if v >= 128 then return "off" end
  return musicutil.note_num_to_name(v, true)
end

-- param id -> function(value) returning the engine key and engine value.
-- used by normal param changes and by sequencer parameter locks, so a
-- lock always behaves exactly like turning the knob.
local ENGINE_MAP = {}

local function send_param(id, v) engine.param(ENGINE_MAP[id](v)) end

local function ctl(id, name, min, max, warp, default, units, quantum, fmt)
  params:add_control(id, name,
    controlspec.new(min, max, warp, 0, default, units or "", quantum), fmt)
  ENGINE_MAP[id] = function(v) return id, v end
  params:set_action(id, function(v) send_param(id, v) end)
end

local function opt(id, name, list, default)
  params:add_option(id, name, list, default)
  ENGINE_MAP[id] = function(v) return id, v - 1 end
  params:set_action(id, function(v) send_param(id, v) end)
end

local function is_audio(path)
  if path == nil or path == "" then return false end
  local l = path:lower()
  return l:match("%.wav$") or l:match("%.aiff?$") or l:match("%.flac$")
end

-- ---------- waveform display (via softcut render) ----------

local function load_display(path)
  local _, samples, rate = audio.file_info(path)
  if not samples or samples <= 0 then return end
  local dur = math.min(samples / rate, softcut.BUFFER_SIZE or 340)
  grains = {}
  softcut.buffer_clear_channel(1)
  softcut.buffer_read_mono(path, 0, 0, dur, 1, 1)
  clock.run(function()
    clock.sleep(0.5)
    softcut.render_buffer(1, 0, dur, 128)
  end)
end

local function on_render(ch, start, i, s)
  waveform = s
  wave_peak = 0.001
  for _, v in ipairs(s) do wave_peak = math.max(wave_peak, math.abs(v)) end
end

-- ---------- grain visualizer ----------
-- the engine reports grains it actually triggers (thinned to ~30/s per
-- voice) over OSC: position, size, playback speed, pitch-spray offset, pan.
-- grains are drawn at their pan: left = top of the strip, right = bottom.

-- same window bank the engine builds: 8 'sides' x 9 'tilt' steps
local SIDES = {0.05, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0}

local function grain_env(x)
  local s = SIDES[util.round(util.clamp(params:get("sides"), 0, 1) * 7) + 1]
  local t = (util.round((util.clamp(params:get("tilt"), -1, 1) + 1) * 4) - 4) / 4
  local p = 0.5 + t * 0.48
  local a, r = math.max(s * p, 0.005), math.max(s * (1 - p), 0.005)
  if x < a then return 0.5 - 0.5 * math.cos(math.pi * x / a) end
  if x > 1 - r then return 0.5 - 0.5 * math.cos(math.pi * (1 - x) / r) end
  return 1
end

local function add_grain(pos, size, speed, semi, pan)
  table.insert(grains, {
    pos = pos, born = util.time(), life = math.max(size, 0.005), speed = speed,
    -- vertical position = stereo pan: left at the top, right at the bottom
    y = util.clamp(pan or 0, -1, 1) * 0.95 + (math.random() * 0.06 - 0.03),
  })
  if #grains > MAX_GRAINS then table.remove(grains, 1) end
end

local function update_grains(now)
  local i = 1
  while i <= #grains do
    if now - grains[i].born >= grains[i].life then table.remove(grains, i) else i = i + 1 end
  end
end

-- all strip drawing takes (top, h): the strip's top y and height in px

local function draw_spray_bands(top, h)
  local w = params:get("spray") * 128
  if w < 1 then return end
  screen.level(1)
  for _, ph in pairs(playheads) do
    local x0 = ph.pos * 128 - w / 2
    screen.rect(x0, top, w, h)
    if x0 < 0 then screen.rect(x0 + 128, top, w, h) end
    if x0 + w > 128 then screen.rect(x0 - 128, top, w, h) end
    screen.fill()
  end
end

local function draw_waveform(top, h)
  local mid, half = top + h / 2, h / 2 - 1
  if waveform then
    screen.level(2)
    for i = 1, #waveform do
      local a = math.max(0.5, math.abs(waveform[i]) / wave_peak * half)
      screen.move(i - 0.5, mid - a)
      screen.line(i - 0.5, mid + a)
    end
    screen.stroke()
  else
    screen.level(4)
    screen.move(64, mid + 3)
    screen.text_center(recording and "recording..." or "K2 tap: rec / hold: load")
  end
end

local function draw_pos_marker(top, h)
  screen.level(6)
  local px = math.floor(params:get("pos") * 127)
  screen.move(px + 0.5, top)
  screen.line(px + 0.5, top + h)
  screen.stroke()
end

local function draw_grains(now, top, h)
  local mid, half = top + h / 2, h / 2 - 1
  for _, g in ipairs(grains) do
    local age = now - g.born
    local phase = age / g.life
    local x0 = g.pos * 127
    -- trail from grain start to its current read head
    local x1 = x0 + age * g.speed * 127
    screen.level(util.clamp(math.floor(2 + grain_env(phase) * 13), 1, 15))
    local y = math.floor(util.clamp(mid + g.y * half, top + 1, top + h - 1))
    local len = math.max(1, math.min(x1 - x0, 128))
    screen.rect(math.floor(x0), y, math.ceil(len), 1)
    if x0 + len > 128 then screen.rect(math.floor(x0) - 128, y, math.ceil(len), 1) end
    screen.fill()
  end
end

local function draw_playheads(top, h)
  local tick = math.max(3, math.floor(h / 7))
  screen.level(15)
  for _, ph in pairs(playheads) do
    local x = math.floor(ph.pos * 127)
    screen.rect(x, top, 1, tick)
    screen.rect(x, top + h - tick, 1, tick)
    screen.fill()
  end
end

local function draw_strip(now, top, h)
  draw_spray_bands(top, h)
  draw_waveform(top, h)
  draw_pos_marker(top, h)
  draw_grains(now, top, h)
  draw_playheads(top, h)
end

-- ---------- voices ----------

local mark_grid = function() end -- set once the grid code is defined

local function update_gate()
  mark_grid()
  if params:get("crowGate") ~= 2 then return end
  local on = #drone_ids > 0 or next(held) ~= nil
  crow.output[1].volts = on and 5 or 0
end

local function pget(id) return params:get(id) end

local function zone_for(note, get)
  get = get or pget
  if note < get("split1") then return 1
  elseif note < get("split2") then return 2
  else return 3 end
end

-- per-note voice settings: zone offsets, plus "note > position" mode,
-- where higher notes read further into the sample (lowest grid note =
-- sample start, `kposSpan` semitones = the whole sample, then it wraps)
local function voice_args(note, get)
  get = get or pget
  local z = zone_for(note, get)
  local pitch_off = get("z" .. z .. "pitch")
  local pos_off = get("z" .. z .. "pos")
  local key_pos = get("z" .. z .. "key")
  local ktrack = get("z" .. z .. "track")
  if get("kposOn") == 2 then
    -- position only: notes always keep their own pitch
    pos_off = pos_off + ((note - params:get("gridBase")) / get("kposSpan")) % 1
  end
  return pitch_off, pos_off, key_pos, ktrack
end

-- `get` / `extra` come from sequencer steps: lock-aware param reader and
-- per-voice engine overrides ("key value key value ...")
local function start_voice(note, vel, get, extra)
  next_id = next_id + 1
  local a, b, c, d = voice_args(note, get)
  if extra and extra ~= "" then
    engine.noteOnL(next_id, note, vel, a, b, c, d, extra)
  else
    engine.noteOn(next_id, note, vel, a, b, c, d)
  end
  return next_id
end

-- ---------- sequencer state ----------
-- 16 steps. each step: on, notes (base notes; chord applied on playback),
-- locks (param id -> value, only for locked params) and probability.

local seq = {
  steps = {}, pos = 0, dir = 1, count = 0, running = false, clock = nil,
  sel = 1,          -- step being edited in the SEQ menu
  held = nil,       -- step held on the grid
  held_t = 0, entered = false,
  voices = {},      -- sounding sequencer voice ids
  sounding = {},    -- note -> count, for grid lights
  globals = {},     -- param ids whose global (shared) lock is applied
}

local function seq_new_step() return {on = false, notes = {}, locks = {}, prob = 1} end
for i = 1, 16 do seq.steps[i] = seq_new_step() end

-- while a grid step is held, keys played (grid or midi) become its notes
local function seq_enter_note(note)
  if not seq.held then return end
  local st = seq.steps[seq.held]
  if not seq.entered then st.notes = {}; seq.entered = true end
  for _, n in ipairs(st.notes) do if n == note then return end end
  table.insert(st.notes, note)
  st.on = true
end

-- chord played by each key: the selected chord when "chord on keys" is on
local function key_intervals()
  if params:get("chordKeys") == 2 then return CHORDS[params:get("droneChord")][2] end
  return {0}
end

-- held[note] = {ids = {voice per chord note}, vel = velocity}
local function stop_held(note)
  local h = held[note]
  if not h then return end
  for _, id in ipairs(h.ids) do engine.noteOff(id) end
  held[note] = nil
end

local function note_on(note, vel)
  seq_enter_note(note)
  stop_held(note)
  sustained[note] = nil
  local ids = {}
  for i, iv in ipairs(key_intervals()) do ids[i] = start_voice(math.min(note + iv, 127), vel) end
  held[note] = {ids = ids, vel = vel}
  update_gate()
end

local function note_off(note)
  if sustain then sustained[note] = true return end
  stop_held(note)
  update_gate()
end

local function release_sustain()
  for note in pairs(sustained) do stop_held(note) end
  sustained = {}
  update_gate()
end

-- retune a playing voice to a new note (keeps its envelope running)
local function retune_voice(id, note, vel)
  local pitch_off, pos_off, key_pos, ktrack = voice_args(note)
  engine.voiceSet(id, "note", note)
  if vel then engine.voiceSet(id, "vel", vel) end
  engine.voiceSet(id, "pitchOff", pitch_off)
  engine.voiceSet(id, "posOff", pos_off)
  engine.voiceSet(id, "keyPos", key_pos)
  engine.voiceSet(id, "ktrack", ktrack)
end

-- re-apply per-note settings to everything sounding (held notes + drone)
local function refresh_voices()
  local ivs = key_intervals()
  for note, h in pairs(held) do
    for i, id in ipairs(h.ids) do retune_voice(id, math.min(note + (ivs[i] or 0), 127)) end
  end
  if #drone_ids > 0 then
    local root = params:get("droneRoot")
    for i, iv in ipairs(CHORDS[params:get("droneChord")][2]) do
      if drone_ids[i] then retune_voice(drone_ids[i], root + iv) end
    end
  end
end

-- move a playing chord to new intervals: shared voices glide to their new
-- notes, extra notes start, leftover voices release. returns the new ids.
local function apply_chord(base, ids, vel, ivs)
  local out = {}
  for i, iv in ipairs(ivs) do
    local n = math.min(base + iv, 127)
    if ids[i] then
      retune_voice(ids[i], n, vel)
      out[i] = ids[i]
    else
      out[i] = start_voice(n, vel)
    end
  end
  for i = #ivs + 1, #ids do engine.noteOff(ids[i]) end
  return out
end

-- apply drone root / chord / velocity changes to a drone that is playing
local function update_drone()
  mark_grid()
  if #drone_ids == 0 then return end
  drone_ids = apply_chord(params:get("droneRoot"), drone_ids, params:get("droneVel"),
    CHORDS[params:get("droneChord")][2])
end

-- apply chord changes to keys being held (grid / midi)
local function update_keys()
  mark_grid()
  local ivs = key_intervals()
  for note, h in pairs(held) do h.ids = apply_chord(note, h.ids, h.vel, ivs) end
end

-- ---------- sequencer playback ----------

local SEQ_DIVS = {{"1/32", 1 / 8}, {"1/16", 1 / 4}, {"1/8", 1 / 2}, {"1/4", 1}, {"1/2", 2}, {"1 bar", 4}}
local SEQ_DIRS = {"forward", "reverse", "ping-pong", "random"}

-- params the script itself uses when starting notes (lockable per step)
local LUA_LOCKS = {gridVel = true, droneChord = true, chordKeys = true,
  kposOn = true, kposSpan = true, split1 = true, split2 = true}
for z = 1, 3 do
  for _, k in ipairs({"pitch", "pos", "key", "track"}) do LUA_LOCKS["z" .. z .. k] = true end
end
-- engine params shared by every voice (effects / output): a lock on these
-- is applied while its step plays and restored at the next triggered step
local GLOBAL_LOCKS = {drive = true, crush = true, dtime = true, dfb = true, dmix = true,
  rsize = true, rdamp = true, rmix = true, level = true}
-- per-voice, but also drive the free-running scan / lfos: set both ways
local BOTH_LOCKS = {scan = true, l1shape = true, l1rate = true, l2shape = true,
  l2rate = true, l12x = true}

local function lockable(id) return ENGINE_MAP[id] ~= nil or LUA_LOCKS[id] == true end

local function seq_div() return SEQ_DIVS[params:get("seqDiv")][2] end

local function seq_release(ids, notes)
  for _, id in ipairs(ids) do
    if seq.voices[id] then engine.noteOff(id); seq.voices[id] = nil end
  end
  for _, n in ipairs(notes) do
    seq.sounding[n] = (seq.sounding[n] or 1) - 1
    if seq.sounding[n] <= 0 then seq.sounding[n] = nil end
  end
  mark_grid()
end

local function seq_apply_globals(locks)
  for id in pairs(seq.globals) do
    if locks[id] == nil then send_param(id, params:get(id)); seq.globals[id] = nil end
  end
  for id, v in pairs(locks) do
    if GLOBAL_LOCKS[id] or BOTH_LOCKS[id] then send_param(id, v); seq.globals[id] = true end
  end
end

local function seq_voice_extra(locks)
  local parts = {}
  for id, v in pairs(locks) do
    if ENGINE_MAP[id] and not GLOBAL_LOCKS[id] then
      local k, val = ENGINE_MAP[id](v)
      parts[#parts + 1] = k .. " " .. val
    end
  end
  return table.concat(parts, " ")
end

local function seq_play_step(i)
  local st = seq.steps[i]
  if not st or not st.on or #st.notes == 0 then return end
  if st.prob < 1 and math.random() > st.prob then return end
  local L = st.locks
  seq_apply_globals(L)
  local get = function(id)
    local v = L[id]
    if v == nil then return params:get(id) end
    return v
  end
  local vel = get("gridVel")
  local ivs = get("chordKeys") == 2 and CHORDS[get("droneChord")][2] or {0}
  local extra = seq_voice_extra(L)
  local ids, notes = {}, {}
  for _, n in ipairs(st.notes) do
    for _, iv in ipairs(ivs) do
      local nn = math.min(n + iv, 127)
      local id = start_voice(nn, vel, get, extra)
      ids[#ids + 1] = id
      notes[#notes + 1] = nn
      seq.voices[id] = true
      seq.sounding[nn] = (seq.sounding[nn] or 0) + 1
    end
  end
  local gate = clock.get_beat_sec() * seq_div() * params:get("seqGate")
  clock.run(function() clock.sleep(gate); seq_release(ids, notes) end)
end

local function seq_advance()
  local len = params:get("seqLen")
  local d = params:get("seqDir")
  if d == 1 then
    seq.pos = seq.pos % len + 1
  elseif d == 2 then
    seq.pos = seq.pos - 1
    if seq.pos < 1 or seq.pos > len then seq.pos = len end
  elseif d == 3 then
    if len == 1 then seq.pos = 1 else
      local nxt = seq.pos + seq.dir
      if nxt > len or nxt < 1 then seq.dir = -seq.dir; nxt = seq.pos + seq.dir end
      seq.pos = util.clamp(nxt, 1, len)
    end
  else
    seq.pos = math.random(len)
  end
end

local function seq_loop()
  while true do
    clock.sync(seq_div())
    seq_advance()
    seq.count = seq.count + 1
    local sw = params:get("seqSwing")
    if sw > 0 and seq.count % 2 == 0 then
      clock.sleep(clock.get_beat_sec() * seq_div() * sw * 0.5)
    end
    seq_play_step(seq.pos)
    mark_grid()
  end
end

local function seq_start()
  if seq.running then return end
  seq.running, seq.pos, seq.dir, seq.count = true, 0, 1, 0
  seq.clock = clock.run(seq_loop)
  mark_grid()
end

local function seq_stop()
  if not seq.running then return end
  seq.running = false
  if seq.clock then clock.cancel(seq.clock); seq.clock = nil end
  for id in pairs(seq.voices) do engine.noteOff(id) end
  seq.voices, seq.sounding = {}, {}
  seq_apply_globals({})
  seq.pos = 0
  mark_grid()
end

local function seq_clear_all_locks()
  for _, st in ipairs(seq.steps) do st.locks = {} end
  seq_apply_globals({})
end

local function seq_clear_pattern()
  for i = 1, 16 do seq.steps[i] = seq_new_step() end
  seq_apply_globals({})
  mark_grid()
end

local function toggle_drone()
  if #drone_ids > 0 then
    for _, id in ipairs(drone_ids) do engine.noteOff(id) end
    drone_ids = {}
  else
    local root = params:get("droneRoot")
    local vel = params:get("droneVel")
    for _, iv in ipairs(CHORDS[params:get("droneChord")][2]) do
      table.insert(drone_ids, start_voice(root + iv, vel))
    end
  end
  update_gate()
end

-- ---------- midi / crow ----------

local function midi_event(data)
  local msg = midi.to_msg(data)
  local ch = params:get("midiCh")
  if ch > 1 and msg.ch ~= ch - 1 then return end
  if msg.type == "note_on" then
    if msg.vel > 0 then note_on(msg.note, msg.vel / 127) else note_off(msg.note) end
  elseif msg.type == "note_off" then
    note_off(msg.note)
  elseif msg.type == "cc" then
    if msg.cc == 1 then
      engine.ctl(0, msg.val / 127)
    elseif msg.cc == 64 then
      sustain = msg.val >= 64
      if not sustain then release_sustain() end
    end
  elseif msg.type == "channel_pressure" then
    engine.ctl(1, msg.val / 127)
  elseif msg.type == "pitchbend" then
    engine.param("bend", ((msg.val - 8192) / 8192) * params:get("bendRange"))
  end
end

local function connect_midi(dev)
  if m then m.event = nil end
  m = midi.connect(dev)
  m.event = midi_event
end

local function setup_crow_cv(on)
  for n = 1, 2 do
    if on then
      crow.input[n].stream = function(v) engine.ctl(n + 1, util.clamp(v / 5, -1, 1)) end
      crow.input[n].mode("stream", 0.02)
    else
      crow.input[n].mode("none")
    end
  end
end

-- ---------- grid: linnstrument-style isomorphic keyboard ----------
-- columns step +1 semitone, rows step up by `gridRow` semitones (default
-- a fourth), bottom-left = `gridBase`. root notes and scale notes are lit;
-- a pressed note lights every pad that plays the same pitch, as do notes
-- coming from the drone or midi.

local g = nil
local grid_dirty = true
local grid_keys = {}   -- "x,y" -> note held by that pad
local grid_count = {}  -- note -> number of pads holding it
local SCALE_NAMES = {"chromatic"}
for _, sc in ipairs(musicutil.SCALES) do table.insert(SCALE_NAMES, sc.name) end
local KEY_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

local function grid_present() return g ~= nil and (g.device ~= nil or (g.cols or 0) > 0) end
local function grid_enabled() return grid_present() and params:get("gridOn") == 2 end

local function grid_rows() return (g and g.rows and g.rows > 0) and g.rows or 8 end
local function grid_cols() return (g and g.cols and g.cols > 0) and g.cols or 16 end

-- physical pad -> keyboard layout position (and back; each mapping is its
-- own inverse). "normal" = (1,1) top-left as monome numbers it.
local function grid_orient(x, y)
  local o = params:get("gridOrient")
  if o == 2 then return grid_cols() + 1 - x, grid_rows() + 1 - y end -- rotated 180
  if o == 3 then return x, grid_rows() + 1 - y end                   -- flipped vertically
  if o == 4 then return grid_cols() + 1 - x, y end                   -- flipped horizontally
  return x, y
end

local function grid_note(x, y)
  return params:get("gridBase") + (x - 1) + (grid_rows() - y) * params:get("gridRow")
end

local function in_scale(pc)
  local si = params:get("gridScale")
  if si == 1 then return true end
  local root = params:get("gridKey") - 1
  for _, iv in ipairs(musicutil.SCALES[si - 1].intervals) do
    if (root + iv) % 12 == pc then return true end
  end
  return false
end

local function seq_row_on() return params:get("seqRow") == 2 end

local function sounding_notes()
  local on = {}
  for n in pairs(seq.sounding) do on[n] = true end
  local ivs = key_intervals()
  for note, h in pairs(held) do
    for i in ipairs(h.ids) do on[math.min(note + (ivs[i] or 0), 127)] = true end
  end
  if #drone_ids > 0 then
    local root = params:get("droneRoot")
    for _, iv in ipairs(CHORDS[params:get("droneChord")][2]) do on[root + iv] = true end
  end
  return on
end

-- top row: 16 steps. dim = empty, mid = has notes, bright = on,
-- brighter = on with locks, full = playhead / held step
local function seq_step_led(x)
  local st = seq.steps[x]
  if not st then return 0 end
  local has_locks = next(st.locks) ~= nil
  local lvl
  if #st.notes == 0 then lvl = has_locks and 2 or 1
  elseif st.on then lvl = has_locks and 10 or 7
  else lvl = 3 end
  if x > params:get("seqLen") then lvl = math.min(lvl, 1) end
  if view == "seq" and x == seq.sel then lvl = math.max(lvl, 12) end
  if (seq.running and x == seq.pos) or seq.held == x then lvl = 15 end
  return lvl
end

-- press: select step + open SEQ menu; hold + play keys: set its notes;
-- quick tap (no notes played): step on / off
local function seq_grid_key(x, z)
  if x > 16 then return end
  if z == 1 then
    seq.held, seq.held_t, seq.entered = x, util.time(), false
    seq.sel = x
    view = "seq"
    last_touch = util.time()
  elseif seq.held == x then
    local st = seq.steps[x]
    if not seq.entered and util.time() - seq.held_t < 0.3 then
      if #st.notes > 0 then
        st.on = not st.on
      else
        show_notice("hold step + play keys", 1.2)
      end
    end
    seq.held = nil
    last_touch = util.time()
  end
  grid_dirty = true
end

local function grid_redraw()
  if not g then return end
  if not grid_enabled() then g:all(0); g:refresh(); return end
  local on = sounding_notes()
  local root = params:get("gridKey") - 1
  local scale_lvl = params:get("gridScale") == 1 and 0 or 2
  local seq_row = seq_row_on()
  -- notes of the step being edited (SEQ menu open)
  local step_notes = {}
  if view == "seq" then
    for _, n in ipairs(seq.steps[seq.sel].notes) do step_notes[n] = true end
  end
  g:all(0)
  for x = 1, grid_cols() do
    for y = 1, grid_rows() do
      local lvl = 0
      if seq_row and y == 1 then
        lvl = seq_step_led(x)
      else
        local note = grid_note(x, y)
        local pc = note % 12
        if grid_keys[x .. "," .. y] then lvl = 15
        elseif on[note] then lvl = 9
        elseif step_notes[note] then lvl = 7
        elseif pc == root then lvl = 5
        elseif in_scale(pc) then lvl = scale_lvl end
        if note > 127 or note < 0 then lvl = 0 end
      end
      local px, py = grid_orient(x, y)
      g:led(px, py, lvl)
    end
  end
  g:refresh()
end

local function grid_key(px, py, z)
  local x, y = grid_orient(px, py)
  if seq_row_on() and y == 1 then
    if params:get("gridOn") == 2 or z == 0 then seq_grid_key(x, z) end
    return
  end
  local k = x .. "," .. y
  if z == 1 then
    if params:get("gridOn") ~= 2 then return end
    local note = grid_note(x, y)
    if note < 0 or note > 127 then return end
    show_notice(musicutil.note_num_to_name(note, true), 0.7)
    grid_keys[k] = note
    grid_count[note] = (grid_count[note] or 0) + 1
    note_on(note, params:get("gridVel"))
  else
    local note = grid_keys[k]
    if not note then return end
    grid_keys[k] = nil
    grid_count[note] = (grid_count[note] or 1) - 1
    if grid_count[note] <= 0 then
      grid_count[note] = nil
      note_off(note)
    end
  end
  grid_dirty = true
end

mark_grid = function() grid_dirty = true end

local function grid_release_all()
  for _, note in pairs(grid_keys) do note_off(note) end
  grid_keys, grid_count = {}, {}
  grid_dirty = true
end

local function port_has_grid(n)
  local v = grid.vports and grid.vports[n]
  return v ~= nil and (v.device ~= nil or (v.cols or 0) > 0)
end

-- connect to the chosen port; if nothing is on it, use the first port
-- that does have a grid (norns may put a grid on any of ports 1-4)
local function connect_grid(dev)
  if g then grid_release_all(); g.key = nil end
  local port = dev
  if not port_has_grid(port) then
    for n = 1, 4 do
      if port_has_grid(n) then port = n; break end
    end
  end
  g = grid.connect(port)
  g.key = grid_key
  grid_dirty = true
  if grid_present() then
    print("speculation: grid on port " .. port .. " (" .. tostring(g.name) .. ", "
      .. tostring(g.cols) .. "x" .. tostring(g.rows) .. ")")
  else
    print("speculation: no grid found on ports 1-4 (check SYSTEM > DEVICES > GRID)")
  end
end

-- ---------- params ----------

local function setup_params()
  params:add_separator("gr_sample", "sample")
  params:add_file("sample", "sample", _path.audio)
  params:set_action("sample", function(path)
    if is_audio(path) then
      if recording then
        -- loading discards the take in progress (engine aborts it)
        recording = false
        params:set("record", 0, true)
      end
      engine.loadSample(path)
      load_display(path)
    end
  end)
  params:add_number("recLen", "rec length", 1, 120, 10, function(p) return p:get() .. " s" end)
  params:add_option("recLoop", "rec mode", {"one shot", "looping"}, 1)
  params:add_binary("record", "record", "toggle", 0)
  params:set_action("record", function(v)
    recording = v == 1
    engine.rec(v, params:get("recLen"), params:get("recLoop") - 1)
  end)

  params:add_separator("gr_grain", "grain")
  ctl("pos", "position", 0, 1, "lin", 0, "", 0.002, pct)
  ctl("scan", "scan speed", -2, 2, "lin", 0, "x", 0.0025)
  ctl("spray", "spray", 0, 1, "lin", 0.05, "", 0.005, pct)
  ctl("size", "grain size", 0.005, 5, "exp", 0.15, "", 0.005, secs)
  ctl("dens", "density", 0.5, 64, "exp", 6, "", 0.005)
  ctl("pspr", "pitch spray", 0, 24, "lin", 0, "st", 1 / 240)
  ctl("sides", "sides", 0, 1, "lin", 0.7, "", 1 / 70, pct)
  ctl("tilt", "tilt", -1, 1, "lin", 0, "", 1 / 80, bip)
  ctl("pan", "pan", -1, 1, "lin", 0, "", 0.01, bip)
  ctl("panSpr", "pan spray", 0, 1, "lin", 0.4, "", 0.01, pct)
  ctl("spawnRand", "spawn random", 0, 1, "lin", 0, "", 0.01, pct)
  opt("scanMode", "scan mode", {"loop", "ping pong", "one shot"}, 1)
  opt("scanSync", "scan key sync", {"off", "on"}, 1)

  params:add_separator("gr_voice", "pitch / amp")
  params:add_number("tune", "tune", -24, 24, 0, function(p) return string.format("%+d st", p:get()) end)
  ENGINE_MAP.tune = function(v) return "tune", v end
  params:set_action("tune", function(v) send_param("tune", v) end)
  ctl("fine", "fine", -100, 100, "lin", 0, "ct", 0.005)
  ENGINE_MAP.fine = function(v) return "fine", v / 100 end
  params:set_action("fine", function(v) send_param("fine", v) end)
  ctl("glide", "granular glide", 0, 5, "lin", 0, "s", 0.002)
  params:add_number("bendRange", "bend range", 0, 24, 2)
  ctl("sub", "sub-osc", 0, 1, "lin", 0, "", 0.01, pct)
  ctl("amp", "level", 0, 1, "lin", 0.5, "", 0.01, pct)
  ctl("velSens", "velocity sens", 0, 1, "lin", 0.5, "", 0.01, pct)
  ctl("atk", "attack", 0.001, 10, "exp", 0.05, "", 0.005, secs)
  ctl("dec", "decay", 0.001, 10, "exp", 0.3, "", 0.005, secs)
  ctl("sus", "sustain", 0, 1, "lin", 1, "", 0.01, pct)
  ctl("rel", "release", 0.01, 10, "exp", 1.5, "", 0.005, secs)
  params:add_number("poly", "polyphony", 1, 16, 8)
  params:set_action("poly", function(v) engine.poly(v) end)

  params:add_separator("gr_filter", "filter")
  opt("fmode", "filter mode", {"LPF", "HPF", "BPF", "off"}, 1)
  ctl("cutoff", "cutoff", 20, 18000, "exp", 12000, "hz", 0.005)
  ctl("res", "resonance", 0, 1, "lin", 0.1, "", 0.01, pct)
  ctl("fenv", "env amount", -1, 1, "lin", 0, "", 0.01, bip)
  ctl("fatk", "f attack", 0.001, 10, "exp", 0.01, "", 0.005, secs)
  ctl("fdec", "f decay", 0.001, 10, "exp", 0.5, "", 0.005, secs)
  ctl("fsus", "f sustain", 0, 1, "lin", 0.5, "", 0.01, pct)
  ctl("frel", "f release", 0.01, 10, "exp", 1, "", 0.005, secs)

  params:add_separator("gr_lfo", "lfo")
  local shapes = {"sine", "tri", "saw", "square", "random"}
  opt("l1shape", "lfo1 shape", shapes, 1)
  ctl("l1rate", "lfo1 rate", 0.01, 30, "exp", 1, "hz", 0.005)
  opt("l1sync", "lfo1 key sync", {"off", "on"}, 1)
  opt("l2shape", "lfo2 shape", shapes, 1)
  ctl("l2rate", "lfo2 rate", 0.01, 30, "exp", 0.5, "hz", 0.005)
  opt("l2sync", "lfo2 key sync", {"off", "on"}, 1)
  ctl("l12x", "lfo1>2 cross mod", 0, 1, "lin", 0, "", 0.01, pct)

  params:add_separator("gr_matrix", "mod matrix")
  for i = 1, 8 do
    local d = MATRIX_DEFAULTS[i]
    params:add_option("m" .. i .. "src", i .. " source", SRC, d[1])
    ENGINE_MAP["m" .. i .. "src"] = function(v) return "msrc" .. (i - 1), v - 1 end
    params:set_action("m" .. i .. "src", function(v) send_param("m" .. i .. "src", v) end)
    params:add_option("m" .. i .. "dst", i .. " dest", DST, d[2])
    ENGINE_MAP["m" .. i .. "dst"] = function(v) return "mdst" .. (i - 1), v - 1 end
    params:set_action("m" .. i .. "dst", function(v) send_param("m" .. i .. "dst", v) end)
    params:add_control("m" .. i .. "amt", i .. " amount",
      controlspec.new(-1, 1, "lin", 0, d[3], "", 0.005), bip)
    ENGINE_MAP["m" .. i .. "amt"] = function(v) return "mamt" .. (i - 1), v end
    params:set_action("m" .. i .. "amt", function(v) send_param("m" .. i .. "amt", v) end)
  end

  params:add_separator("gr_fx", "fx")
  ctl("drive", "distort", 0, 1, "lin", 0, "", 0.01, pct)
  ctl("crush", "reducer", 0, 1, "lin", 0, "", 0.01, pct)
  ctl("dtime", "delay time", 0.01, 2, "exp", 0.375, "", 0.005, secs)
  ctl("dfb", "delay feedback", 0, 0.95, "lin", 0.35, "", 0.01, pct)
  ctl("dmix", "delay mix", 0, 1, "lin", 0, "", 0.01, pct)
  ctl("rsize", "reverb size", 0, 1, "lin", 0.8, "", 0.01, pct)
  ctl("rdamp", "reverb damp", 0, 1, "lin", 0.4, "", 0.01, pct)
  ctl("rmix", "reverb mix", 0, 1, "lin", 0.2, "", 0.01, pct)
  ctl("level", "output level", 0, 1.5, "lin", 1, "", 0.01, pct)

  params:add_separator("gr_zones", "keyboard zones")
  params:add_number("split1", "split A|B", 0, 128, 128, note_fmt)
  params:add_number("split2", "split B|C", 0, 128, 128, note_fmt)
  for z = 1, 3 do
    params:add_number("z" .. z .. "pitch", ZONES[z] .. " pitch", -24, 24, 0,
      function(p) return string.format("%+d st", p:get()) end)
    params:add_control("z" .. z .. "pos", ZONES[z] .. " pos offset",
      controlspec.new(-1, 1, "lin", 0, 0, "", 0.005), bip)
    params:add_control("z" .. z .. "key", ZONES[z] .. " key>pos",
      controlspec.new(-1, 1, "lin", 0, 0, "", 0.005), bip)
    params:add_control("z" .. z .. "track", ZONES[z] .. " key>pitch",
      controlspec.new(0, 1, "lin", 0, 1, "", 0.01), pct)
  end

  params:add_separator("gr_play", "play mode")
  params:add_number("droneRoot", "drone root", 24, 96, 48, note_fmt)
  params:set_action("droneRoot", function() update_drone() end)
  local chord_names = {}
  for i, c in ipairs(CHORDS) do chord_names[i] = c[1] end
  params:add_option("droneChord", "chord", chord_names, 1)
  params:set_action("droneChord", function() update_drone(); update_keys() end)
  params:add_option("chordKeys", "chord on keys", {"off", "on"}, 2)
  params:set_action("chordKeys", function() update_keys() end)
  params:add_control("droneVel", "drone velocity", controlspec.new(0, 1, "lin", 0, 0.8, "", 0.01), pct)
  params:set_action("droneVel", function() update_drone() end)

  params:add_separator("gr_io", "midi / crow")
  params:add_number("midiDev", "midi device", 1, 16, 1)
  params:set_action("midiDev", function(v) connect_midi(v) end)
  local chs = {"all"}
  for i = 1, 16 do chs[i + 1] = tostring(i) end
  params:add_option("midiCh", "midi channel", chs, 1)
  params:add_option("crowCv", "crow in 1/2 > cv1/cv2", {"off", "on"}, 1)
  params:set_action("crowCv", function(v) setup_crow_cv(v == 2) end)
  params:add_option("crowGate", "crow out 1 gate", {"off", "on"}, 1)

  params:add_separator("gr_seq", "sequencer")
  local div_names = {}
  for i, dv in ipairs(SEQ_DIVS) do div_names[i] = dv[1] end
  params:add_option("seqDiv", "step size", div_names, 2)
  params:add_number("seqLen", "length", 1, 16, 16)
  params:set_action("seqLen", function() grid_dirty = true end)
  params:add_option("seqDir", "direction", SEQ_DIRS, 1)
  params:add_control("seqSwing", "swing", controlspec.new(0, 1, "lin", 0, 0, "", 0.01), pct)
  params:add_control("seqGate", "gate", controlspec.new(0.05, 1, "lin", 0, 0.5, "", 0.01), pct)

  params:add_separator("gr_grid", "grid keyboard")
  params:add_option("gridOn", "grid keyboard", {"off", "on"}, 2)
  params:set_action("gridOn", function(v)
    if v == 1 then grid_release_all() end
    grid_dirty = true
  end)
  params:add_number("gridDev", "grid device", 1, 4, 1)
  params:set_action("gridDev", function(v) connect_grid(v) end)
  params:add_option("seqRow", "top row", {"keyboard", "sequencer"}, 2)
  params:set_action("seqRow", function() grid_release_all() end)
  params:add_option("gridOrient", "orientation",
    {"normal", "rotated 180", "flip vertical", "flip horizontal"}, 1)
  params:set_action("gridOrient", function() grid_release_all() end)
  params:add_number("gridBase", "lowest note", 0, 72, 36, note_fmt)
  params:set_action("gridBase", function() grid_release_all() end)
  params:add_number("gridRow", "row interval", 1, 12, 5, function(p)
    local names = {[3] = "min 3rd", [4] = "maj 3rd", [5] = "4th", [7] = "5th", [12] = "octave"}
    return names[p:get()] or (p:get() .. " st")
  end)
  params:set_action("gridRow", function() grid_release_all() end)
  params:add_option("gridKey", "key", KEY_NAMES, 1)
  params:set_action("gridKey", function() grid_dirty = true end)
  params:add_option("gridScale", "scale lights", SCALE_NAMES, 2)
  params:set_action("gridScale", function() grid_dirty = true end)
  params:add_control("gridVel", "grid velocity", controlspec.new(0, 1, "lin", 0, 0.8, "", 0.01), pct)
  params:add_option("kposOn", "note > pos", {"off", "on"}, 1)
  params:set_action("kposOn", function() refresh_voices() end)
  params:add_number("kposSpan", "pos span", 1, 96, 24, function(p)
    return p:get() .. " st"
  end)
  params:set_action("kposSpan", function() refresh_voices() end)
end

local function build_pages()
  local mtx = {}
  for i = 1, 8 do
    table.insert(mtx, "m" .. i .. "src")
    table.insert(mtx, "m" .. i .. "dst")
    table.insert(mtx, "m" .. i .. "amt")
  end
  local zones = {"split1", "split2"}
  for z = 1, 3 do
    for _, k in ipairs({"pitch", "pos", "key", "track"}) do table.insert(zones, "z" .. z .. k) end
  end
  pages = {
    {name = "GRAIN", ids = {"pos", "scan", "spray", "size", "dens", "pspr", "sides", "tilt",
      "pan", "panSpr", "spawnRand", "scanMode", "scanSync"}},
    {name = "VOICE", ids = {"tune", "fine", "glide", "sub", "amp", "velSens",
      "atk", "dec", "sus", "rel", "bendRange", "poly"}},
    {name = "FILTER", ids = {"fmode", "cutoff", "res", "fenv", "fatk", "fdec", "fsus", "frel"}},
    {name = "LFO", ids = {"l1shape", "l1rate", "l1sync", "l2shape", "l2rate", "l2sync", "l12x"}},
    {name = "MATRIX", ids = mtx},
    {name = "FX", ids = {"drive", "crush", "dtime", "dfb", "dmix", "rsize", "rdamp", "rmix", "level"}},
    {name = "ZONES", ids = zones},
    {name = "PLAY / REC", ids = {"droneChord", "chordKeys", "droneRoot", "droneVel", "recLen", "recLoop"}},
  }
  if grid_present() then
    table.insert(pages, {name = "GRID",
      ids = {"gridOn", "seqRow", "gridOrient", "gridBase", "gridRow", "gridKey", "gridScale", "gridVel",
        "kposOn", "kposSpan"}})
  end
  for i = 1, #pages do sel[i] = sel[i] or 1 end
  page = util.clamp(page, 1, #pages)
end

-- ---------- osc from engine ----------

osc.event = function(path, args, from)
  if path == "/grainery/pos" then
    playheads[math.floor(args[1])] = {pos = args[2], t = util.time()}
  elseif path == "/grainery/grain" then
    add_grain(args[2], args[3], args[4], args[5], args[6])
  elseif path == "/grainery/recdone" then
    -- engine has already trimmed the take and loaded it; just show it
    recording = false
    params:set("record", 0, true)
    params:set("sample", args[1], true)
    load_display(args[1])
  end
end

-- ---------- ui ----------

local function touch() last_touch = util.time() end

-- K2 hold: browse norns audio folder (dust/audio) and load a sample
-- ---------- sample library browser (K2 hold) ----------
-- one flat list of every audio file on the norns: dust/audio (tape, other
-- scripts' recordings, sample packs), dust/data and dust/code (samples
-- shipped with or saved by other scripts). rescanned each time it opens.

local LIB_ROOTS = {"audio", "data", "code"}
local LIB_ROWS = 6
local lib_files, lib_sel, lib_prev_view = {}, 1, "home"

local function scan_library()
  local files = {}
  local dust = _path.dust or "/home/we/dust/"
  for _, root in ipairs(LIB_ROOTS) do
    local cmd = "find '" .. dust .. root .. "' -type f -not -path '*/.*' \\( -iname '*.wav'"
      .. " -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.flac' \\) 2>/dev/null | sort -f"
    local h = io.popen(cmd)
    if h then
      for path in h:lines() do
        local rel = path:sub(#dust + 1)
        table.insert(files, {
          path = path,
          name = rel:match("([^/]+)$") or rel,
          folder = rel:match("^(.*)/[^/]+$") or root,
        })
      end
      h:close()
    end
  end
  return files
end

local function open_sample_browser()
  if view == "browse" then return end
  lib_files = scan_library()
  lib_sel = 1
  local cur = params:get("sample")
  for i, f in ipairs(lib_files) do
    if f.path == cur then lib_sel = i; break end
  end
  lib_prev_view = view
  view = "browse"
end

local function close_sample_browser()
  view = lib_prev_view
  touch()
end

local function browse_enc(n, d)
  if #lib_files == 0 then return end
  local step = n == 3 and LIB_ROWS or 1
  lib_sel = util.clamp(lib_sel + d * step, 1, #lib_files)
end

local function browse_key(n, z)
  if z ~= 1 then return end -- ignore releases (e.g. letting go of the K2 hold)
  if n == 2 then
    close_sample_browser()
  elseif n == 3 then
    local f = lib_files[lib_sel]
    close_sample_browser()
    if f then params:set("sample", f.path) end
  end
end

local function trunc(str, max)
  if #str <= max then return str end
  return str:sub(1, max - 2) .. ".."
end

local function redraw_browse()
  screen.level(15)
  screen.move(0, 7)
  screen.text("SAMPLES")
  screen.level(4)
  screen.move(127, 7)
  screen.text_right(#lib_files > 0 and (lib_sel .. "/" .. #lib_files) or "0")
  if #lib_files == 0 then
    screen.level(6)
    screen.move(64, 34)
    screen.text_center("no audio files found")
  else
    local top = util.clamp(lib_sel - 2, 1, math.max(1, #lib_files - LIB_ROWS + 1))
    for r = 0, LIB_ROWS - 1 do
      local i = top + r
      local f = lib_files[i]
      if f then
        local y = 16 + r * 8
        if i == lib_sel then
          screen.level(15)
          screen.move(0, y)
          screen.text(">")
        end
        screen.level(i == lib_sel and 15 or 4)
        screen.move(6, y)
        screen.text(trunc(f.name, 30))
      end
    end
    -- folder of the selected file
    screen.level(3)
    screen.move(0, 63)
    screen.text(trunc(lib_files[lib_sel].folder, 32))
  end
  screen.level(2)
  screen.move(127, 63)
  screen.text_right("K3 load")
end

-- ---------- SEQ menu ----------
-- its own menu: page 1 = sequencer + step settings and clear actions;
-- the other pages copy the sound pages, but E3 sets a lock on the selected
-- step instead of the normal value.  K2 clears the selected lock, K3
-- clears every lock on the step.  K1+K2 leaves, K1+K3 play / stop.

local seq_pages, seq_page, seq_sel = {}, 1, {}
local SEQ_ROWS = 5
local LOCK_LABELS = {gridVel = "velocity", droneChord = "chord"}

local function seq_count_locks(st)
  local n = 0
  for _ in pairs(st.locks) do n = n + 1 end
  return n
end

local function seq_clear_step_locks()
  seq.steps[seq.sel].locks = {}
  show_notice("step " .. seq.sel .. " locks cleared", 1)
  grid_dirty = true
end

local function build_seq_pages()
  local items = {
    {t = "step"}, {t = "run"}, {t = "notes"}, {t = "on"}, {t = "prob"},
    {t = "param", id = "seqDiv"}, {t = "param", id = "seqLen"}, {t = "param", id = "seqDir"},
    {t = "param", id = "seqSwing"}, {t = "param", id = "seqGate"},
    {t = "act", name = "clear step locks", fn = seq_clear_step_locks},
    {t = "act", name = "clear ALL locks", fn = function()
      seq_clear_all_locks(); show_notice("all locks cleared", 1.2); grid_dirty = true end},
    {t = "act", name = "clear pattern", fn = function()
      seq_stop(); seq_clear_pattern(); show_notice("pattern cleared", 1.2) end},
  }
  seq_pages = {{name = "SEQ", items = items}}
  local note_ids = {"gridVel", "droneChord", "chordKeys", "kposOn", "kposSpan"}
  local function lock_page(name, ids)
    local its = {}
    for _, id in ipairs(ids) do
      if lockable(id) and params.lookup[id] then its[#its + 1] = {t = "lock", id = id} end
    end
    if #its > 0 then seq_pages[#seq_pages + 1] = {name = name, items = its, locks = true} end
  end
  lock_page("NOTE", note_ids)
  for _, pg in ipairs(pages) do
    if pg.name ~= "PLAY / REC" and pg.name ~= "GRID" then lock_page(pg.name, pg.ids) end
  end
  for i = 1, #seq_pages do seq_sel[i] = seq_sel[i] or 1 end
  seq_page = util.clamp(seq_page, 1, #seq_pages)
end

-- a param's display string / delta for a value other than its current one,
-- using the param's own formatter and range (set silently, then restored)
local function param_string_for(id, v)
  local base = params:get(id)
  params:set(id, v, true)
  local str = params:string(id)
  params:set(id, base, true)
  return str
end

local function param_delta_for(id, v, d)
  local p = params:lookup_param(id)
  local base = params:get(id)
  params:set(id, v, true)
  if p.controlspec then
    p:set_raw(p.raw + d * (p.controlspec.quantum or 0.01), true)
  else
    p:set(p:get() + d, true)
  end
  local new = params:get(id)
  params:set(id, base, true)
  return new
end

local function note_list(notes)
  if #notes == 0 then return "-" end
  local t = {}
  for i, n in ipairs(notes) do
    if i > 4 then t[#t + 1] = ".."; break end
    t[#t + 1] = musicutil.note_num_to_name(n, true)
  end
  return table.concat(t, " ")
end

local function seq_item_text(it)
  local st = seq.steps[seq.sel]
  if it.t == "step" then return "edit step", tostring(seq.sel)
  elseif it.t == "run" then return "play", seq.running and "playing" or "stopped"
  elseif it.t == "notes" then return "notes", note_list(st.notes)
  elseif it.t == "on" then return "step on", st.on and "on" or "off"
  elseif it.t == "prob" then return "step chance", string.format("%.0f%%", st.prob * 100)
  elseif it.t == "param" then return params:lookup_param(it.id).name, params:string(it.id)
  elseif it.t == "act" then return it.name, "K3"
  elseif it.t == "lock" then
    local name = LOCK_LABELS[it.id] or params:lookup_param(it.id).name
    local v = st.locks[it.id]
    if v ~= nil then return name, param_string_for(it.id, v), true end
    return name, params:string(it.id), false
  end
  return "", ""
end

local function seq_enc(n, d)
  last_touch = util.time()
  if n == 1 then
    seq_page = util.clamp(seq_page + d, 1, #seq_pages)
    return
  end
  local pg = seq_pages[seq_page]
  if n == 2 then
    seq_sel[seq_page] = util.clamp(seq_sel[seq_page] + d, 1, #pg.items)
    return
  end
  local it = pg.items[seq_sel[seq_page]]
  local st = seq.steps[seq.sel]
  if it.t == "step" then seq.sel = util.clamp(seq.sel + d, 1, 16)
  elseif it.t == "run" then if d > 0 then seq_start() else seq_stop() end
  elseif it.t == "on" then st.on = d > 0
  elseif it.t == "prob" then st.prob = util.clamp(st.prob + d * 0.01, 0, 1)
  elseif it.t == "param" then params:delta(it.id, d)
  elseif it.t == "lock" then
    local cur = st.locks[it.id]
    if cur == nil then cur = params:get(it.id) end
    st.locks[it.id] = param_delta_for(it.id, cur, d)
  end
  grid_dirty = true
end

local function seq_key(n, z)
  if z ~= 1 then return end
  last_touch = util.time()
  local pg = seq_pages[seq_page]
  local it = pg.items[seq_sel[seq_page]]
  local st = seq.steps[seq.sel]
  if n == 2 then
    if pg.locks then
      st.locks[it.id] = nil          -- K2: clear this lock
    else
      view = "home"                  -- K2 on the SEQ page: leave
    end
  elseif n == 3 then
    if pg.locks then
      seq_clear_step_locks()         -- K3: clear every lock on the step
    elseif it.t == "act" then it.fn()
    elseif it.t == "run" then if seq.running then seq_stop() else seq_start() end
    elseif it.t == "on" then st.on = not st.on end
  end
  grid_dirty = true
end

local function redraw_seq()
  local pg = seq_pages[seq_page]
  local st = seq.steps[seq.sel]
  -- header
  screen.level(15)
  screen.move(0, 7)
  screen.text(pg.locks and ("LOCK " .. pg.name) or "SEQ")
  screen.level(seq.running and 15 or 4)
  screen.move(127, 7)
  screen.text_right((seq.running and "> " or "") .. "STEP " .. seq.sel)
  -- step bar
  for i = 1, 16 do
    local lvl = seq_step_led(i)
    if i == seq.sel then lvl = 15 end
    screen.level(lvl)
    screen.rect((i - 1) * 8, 10, 7, i == seq.sel and 3 or 2)
    screen.fill()
  end
  -- rows
  local s = seq_sel[seq_page]
  local top = util.clamp(s - 2, 1, math.max(1, #pg.items - SEQ_ROWS + 1))
  for r = 0, SEQ_ROWS - 1 do
    local idx = top + r
    local it = pg.items[idx]
    if it then
      local y = 22 + r * 8
      local name, val, locked = seq_item_text(it)
      local on_row = idx == s
      screen.level(on_row and 15 or 4)
      screen.move(0, y)
      screen.text((on_row and "> " or "  ") .. name .. (locked and " *" or ""))
      if pg.locks then
        screen.level(locked and (on_row and 15 or 11) or (on_row and 6 or 2))
      end
      screen.move(127, y)
      screen.text_right(val)
    end
  end
  -- footer
  screen.level(3)
  screen.move(0, 63)
  if pg.locks then
    screen.text("K2 clr  K3 clr step")
    screen.move(127, 63)
    screen.text_right(seq_count_locks(st) .. " locks")
  else
    screen.text("E1 lock pages  K1+K2 exit")
  end
end

function enc(n, d)
  if view == "browse" then browse_enc(n, d) return end
  if view == "seq" then seq_enc(n, d) return end
  if view == "menu" then touch() end
  if alt then
    if n == 2 then params:delta("pos", d) elseif n == 3 then params:delta("scan", d) end
    return
  end
  if view == "home" then
    -- first E1 turn just opens the menu on the last-used page
    if n == 1 then view = "menu"; touch() end
    return
  end
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
  elseif n == 2 then
    sel[page] = util.clamp(sel[page] + d, 1, #pages[page].ids)
  elseif n == 3 then
    params:delta(pages[page].ids[sel[page]], d)
  end
end

function key(n, z)
  if view == "browse" then
    if n == 1 then alt = z == 1 end
    browse_key(n, z)
    return
  end
  if view == "menu" then touch() end
  if n == 1 then
    alt = z == 1
    return
  end
  -- K1+K2: open / close the SEQ menu, K1+K3: sequencer play / stop
  if alt and z == 1 and (n == 2 or n == 3) then
    if n == 2 then
      view = (view == "seq") and "home" or "seq"
      last_touch = util.time()
    else
      if seq.running then seq_stop() else seq_start() end
      show_notice(seq.running and "seq play" or "seq stop", 0.8)
    end
    grid_dirty = true
    return
  end
  if view == "seq" then seq_key(n, z) return end
  if n == 2 then
    -- tap = record on/off, hold = open sample browser
    if z == 1 then
      if k2_clock then clock.cancel(k2_clock) end
      k2_clock = clock.run(function()
        clock.sleep(K2_HOLD)
        k2_clock = nil
        open_sample_browser()
      end)
    elseif k2_clock then
      clock.cancel(k2_clock)
      k2_clock = nil
      params:set("record", recording and 0 or 1)
    end
  elseif z == 1 and n == 3 then
    toggle_drone()
  end
end

local function status_text()
  return (recording and "REC " or "") .. (seq.running and "SEQ " or "")
    .. (#drone_ids > 0 and "DRONE" or "")
end

local notice_text, notice_until = nil, 0

show_notice = function(text, dur)
  notice_text, notice_until = text, util.time() + (dur or 2)
end

-- brief centered message (e.g. grid connected)
local function draw_notice(now)
  if not notice_text or now > notice_until then return end
  local w = screen.text_extents(notice_text) + 8
  screen.level(0)
  screen.rect(64 - w / 2, 24, w, 13)
  screen.fill()
  screen.level(15)
  screen.rect(64 - w / 2 + 0.5, 24.5, w - 1, 12)
  screen.stroke()
  screen.move(64, 33)
  screen.text_center(notice_text)
end

local function redraw_home(now)
  draw_strip(now, 0, 64)
  local status = status_text()
  if alt then status = "E2 POS  E3 SCAN" end
  if status ~= "" then
    screen.level(0)
    screen.rect(127 - screen.text_extents(status) - 2, 0, 128, 8)
    screen.fill()
    screen.level(recording and 15 or 6)
    screen.move(127, 6)
    screen.text_right(status)
  end
end

local function redraw_menu(now)
  draw_strip(now, 0, 20)

  -- header
  screen.level(15)
  screen.move(0, 28)
  screen.text(alt and "E2 POS  E3 SCAN" or pages[page].name)
  local status = status_text()
  if status == "" then status = page .. "/" .. #pages end
  screen.level(recording and 15 or 4)
  screen.move(127, 28)
  screen.text_right(status)

  -- param rows
  local ids = pages[page].ids
  local s = sel[page]
  local top = util.clamp(s - 2, 1, math.max(1, #ids - 3))
  for r = 0, 3 do
    local idx = top + r
    local id = ids[idx]
    if id then
      local y = 37 + r * 8
      screen.level(idx == s and 15 or 4)
      screen.move(0, y)
      screen.text(params:lookup_param(id).name)
      screen.move(127, y)
      screen.text_right(params:string(id))
    end
  end
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)
  local now = util.time()

  -- expire stale playheads, then advance grain cloud
  for id, ph in pairs(playheads) do
    if now - ph.t > 0.3 then playheads[id] = nil end
  end
  update_grains(now)

  if (view == "menu" or (view == "seq" and not seq.held)) and not alt
    and now - last_touch > MENU_TIMEOUT then
    if view == "seq" then grid_dirty = true end
    view = "home"
  end

  if view == "home" then redraw_home(now)
  elseif view == "browse" then redraw_browse()
  elseif view == "seq" then redraw_seq()
  else redraw_menu(now) end
  draw_notice(now)
  screen.update()
end

-- ---------- lifecycle ----------

function init()
  util.make_dir(_path.audio .. "grainery")
  softcut.buffer_clear()
  softcut.event_render(on_render)
  setup_params()
  build_pages()
  params:bang()
  build_pages() -- grid now connected by params:bang, add GRID page if present
  build_seq_pages()
  -- the pattern (notes, locks) is saved / loaded with each PSET
  local function seq_file(pset) return (pset:gsub("%.pset$", "")) .. ".seq" end
  params.action_write = function(filename) tab.save(seq.steps, seq_file(filename)) end
  params.action_read = function(filename)
    local ok, t = pcall(tab.load, seq_file(filename))
    if not ok or type(t) ~= "table" then return end
    seq_stop()
    for i = 1, 16 do
      local st = t[i] or {}
      seq.steps[i] = {on = st.on == true, notes = st.notes or {}, locks = st.locks or {},
        prob = st.prob or 1}
    end
    grid_dirty = true
  end
  params.action_delete = function(filename) os.remove(seq_file(filename)) end
  -- grid hotplug: show/hide GRID page and tell the player
  local function grid_changed(msg)
    clock.run(function()
      clock.sleep(0.2) -- let norns attach/detach the device first
      build_pages()
      build_seq_pages()
      grid_dirty = true
      if msg == "connected" and not grid_present() then return end
      show_notice("grid " .. msg)
    end)
  end
  grid.add = function()
    clock.run(function()
      clock.sleep(0.1)
      connect_grid(params:get("gridDev")) -- pick up the grid on whatever port it landed
    end)
    grid_changed("connected")
  end
  grid.remove = function() grid_release_all(); grid_changed("disconnected") end
  redraw_metro = metro.init(function()
    redraw()
    -- grid: redraw when something changed (notes from midi/drone included)
    if grid_dirty then grid_dirty = false; grid_redraw() end
  end, 1 / 30, -1)
  redraw_metro:start()
end

function cleanup()
  seq_stop()
  if redraw_metro then redraw_metro:stop() end
  if g then g:all(0); g:refresh() end
  if params:get("crowGate") == 2 then crow.output[1].volts = 0 end
  if params:get("crowCv") == 2 then setup_crow_cv(false) end
end
