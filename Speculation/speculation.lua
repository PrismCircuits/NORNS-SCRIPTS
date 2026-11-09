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
local view = "home"     -- "home" (sample + grains), "menu" or "browse"
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

local function ctl(id, name, min, max, warp, default, units, quantum, fmt)
  params:add_control(id, name,
    controlspec.new(min, max, warp, 0, default, units or "", quantum), fmt)
  params:set_action(id, function(v) engine.param(id, v) end)
end

local function opt(id, name, list, default)
  params:add_option(id, name, list, default)
  params:set_action(id, function(v) engine.param(id, v - 1) end)
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

local function zone_for(note)
  if note < params:get("split1") then return 1
  elseif note < params:get("split2") then return 2
  else return 3 end
end

-- per-note voice settings: zone offsets, plus "note > position" mode,
-- where higher notes read further into the sample (lowest grid note =
-- sample start, `kposSpan` semitones = the whole sample, then it wraps)
local function voice_args(note)
  local z = zone_for(note)
  local pitch_off = params:get("z" .. z .. "pitch")
  local pos_off = params:get("z" .. z .. "pos")
  local key_pos = params:get("z" .. z .. "key")
  local ktrack = params:get("z" .. z .. "track")
  if params:get("kposOn") == 2 then
    pos_off = pos_off + ((note - params:get("gridBase")) / params:get("kposSpan")) % 1
    if params:get("kposPitch") == 1 then ktrack = 0 end
  end
  return pitch_off, pos_off, key_pos, ktrack
end

local function start_voice(note, vel)
  next_id = next_id + 1
  engine.noteOn(next_id, note, vel, voice_args(note))
  return next_id
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

local function sounding_notes()
  local on = {}
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

local function grid_redraw()
  if not g then return end
  if not grid_enabled() then g:all(0); g:refresh(); return end
  local on = sounding_notes()
  local root = params:get("gridKey") - 1
  local scale_lvl = params:get("gridScale") == 1 and 0 or 2
  g:all(0)
  for x = 1, grid_cols() do
    for y = 1, grid_rows() do
      local note = grid_note(x, y)
      local pc = note % 12
      local lvl = 0
      if grid_keys[x .. "," .. y] then lvl = 15
      elseif on[note] then lvl = 9
      elseif pc == root then lvl = 5
      elseif in_scale(pc) then lvl = scale_lvl end
      if note > 127 or note < 0 then lvl = 0 end
      local px, py = grid_orient(x, y)
      g:led(px, py, lvl)
    end
  end
  g:refresh()
end

local function grid_key(px, py, z)
  local x, y = grid_orient(px, py)
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
  params:set_action("tune", function(v) engine.param("tune", v) end)
  ctl("fine", "fine", -100, 100, "lin", 0, "ct", 0.005)
  params:set_action("fine", function(v) engine.param("fine", v / 100) end)
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
    params:set_action("m" .. i .. "src", function(v) engine.param("msrc" .. (i - 1), v - 1) end)
    params:add_option("m" .. i .. "dst", i .. " dest", DST, d[2])
    params:set_action("m" .. i .. "dst", function(v) engine.param("mdst" .. (i - 1), v - 1) end)
    params:add_control("m" .. i .. "amt", i .. " amount",
      controlspec.new(-1, 1, "lin", 0, d[3], "", 0.005), bip)
    params:set_action("m" .. i .. "amt", function(v) engine.param("mamt" .. (i - 1), v) end)
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

  params:add_separator("gr_grid", "grid keyboard")
  params:add_option("gridOn", "grid keyboard", {"off", "on"}, 2)
  params:set_action("gridOn", function(v)
    if v == 1 then grid_release_all() end
    grid_dirty = true
  end)
  params:add_number("gridDev", "grid device", 1, 4, 1)
  params:set_action("gridDev", function(v) connect_grid(v) end)
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
  params:add_option("kposPitch", "pitch", {"fixed", "tracks"}, 1)
  params:set_action("kposPitch", function() refresh_voices() end)
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
      ids = {"gridOn", "gridOrient", "gridBase", "gridRow", "gridKey", "gridScale", "gridVel",
        "kposOn", "kposSpan", "kposPitch"}})
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

function enc(n, d)
  if view == "browse" then browse_enc(n, d) return end
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
  elseif n == 2 then
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
  return (recording and "REC " or "") .. (#drone_ids > 0 and "DRONE" or "")
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

  if view == "menu" and not alt and now - last_touch > MENU_TIMEOUT then
    view = "home"
  end

  if view == "home" then redraw_home(now)
  elseif view == "browse" then redraw_browse()
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
  -- grid hotplug: show/hide GRID page and tell the player
  local function grid_changed(msg)
    clock.run(function()
      clock.sleep(0.2) -- let norns attach/detach the device first
      build_pages()
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
  if redraw_metro then redraw_metro:stop() end
  if g then g:all(0); g:refresh() end
  if params:get("crowGate") == 2 then crow.output[1].volts = 0 end
  if params:get("crowCv") == 2 then setup_crow_cv(false) end
end
