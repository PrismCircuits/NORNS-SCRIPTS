-- panspectra
-- spectral resynthesis
-- inspired by the rossum
-- panharmonium
--
-- audio in -> fft -> strongest
-- partials -> oscillator bank
--
-- E1 page
-- E2 / E3 adjust
-- K2 freeze
-- K3 capture slice (frozen)
-- hold K3 + turn: fine adjust
--
-- last page: mod matrix
-- E2 select field, E3 edit

engine.name = "PanSpectra"

local NUM_SLOTS = 10

local spectrum = {}
local peaks = {}
local page = 1
local saved_monitor = nil

local BASE = 50
local H = 36

local pages = {
  {{"voices", "vox"}, {"slice_rate", "rate"}},
  {{"center", "ctr"}, {"width", "bw"}},
  {{"stability", "lock"}, {"threshold", "thresh"}},
  {{"fade", "fade"}, {"blur", "blur"}},
  {{"attack", "atk"}, {"release", "rel"}},
  {{"pitch", "pitch"}, {"shift", "shift"}},
  {{"wave", "wave"}, {"flatten", "flat"}},
  {{"glide", "glide"}, {"spread", "spread"}},
  {{"filter_type", "filt"}, {"cutoff", "cut"}},
  {{"resonance", "res"}, {"feedback", "fdbk"}},
  {{"mix", "mix"}, {"level", "level"}},
  {{"input_gain", "gain"}},
}
local MOD_PAGE = #pages + 1

-- mod matrix definitions -----------------------------------------------------
-- (order of SRC and DEST lists must match the engine's indices)

local SRC_NAMES = {"off", "sine", "triangle", "saw", "ramp", "square"}
local SRC_SHORT = {"--", "SIN", "TRI", "SAW", "RMP", "SQR"}
local SQUARE = 6

-- id: param id, short: table column, name: full description, pname: PARAMS menu name
local DESTS = {
  {short = "--", name = "none"},
  {id = "center", short = "center", name = "center frequency", pname = "center"},
  {id = "width", short = "bwidth", name = "bandwidth", pname = "bandwidth"},
  {id = "pitch", short = "pitch", name = "pitch", pname = "pitch"},
  {id = "shift", short = "fshift", name = "frequency shift", pname = "freq shift"},
  {id = "wave", short = "wave", name = "waveform", pname = "waveform"},
  {id = "flatten", short = "flatten", name = "flatten", pname = "flatten"},
  {id = "voices", short = "voices", name = "voice count", pname = "voices"},
  {id = "slice_rate", short = "slice", name = "slice rate", pname = "slice rate"},
  {id = "stability", short = "lock", name = "lock / stability", pname = "stability"},
  {id = "threshold", short = "thresh", name = "threshold", pname = "threshold"},
  {id = "blur", short = "blur", name = "spectral blur", pname = "blur"},
  {id = "glide", short = "glide", name = "glide", pname = "glide"},
  {id = "spread", short = "spread", name = "stereo spread", pname = "stereo spread"},
  {id = "feedback", short = "fdbk", name = "feedback", pname = "feedback"},
  {id = "mix", short = "mix", name = "dry/wet mix", pname = "dry/wet"},
  {id = "level", short = "level", name = "output level", pname = "output level"},
  {id = "input_gain", short = "in gain", name = "input gain", pname = "input gain"},
  {id = "cutoff", short = "cutoff", name = "filter cutoff", pname = "cutoff"},
  {id = "resonance", short = "reso", name = "filter resonance", pname = "resonance"},
  {id = "attack", short = "attack", name = "envelope attack", pname = "attack"},
  {id = "release", short = "release", name = "envelope release", pname = "release"},
  {id = "fade", short = "fade", name = "band volume fade", pname = "fade"},
}
local DEST_NAMES = {}
for i, d in ipairs(DESTS) do DEST_NAMES[i] = d.name end

local FIELD_PREFIX = {"mod_src_", "mod_rate_", "mod_pw_", "mod_dst_", "mod_amt_"}
local FIELD_X = {12, 30, 52, 66, 127} -- amt is right-aligned
local FIELD_HEAD = {"SRC", "HZ", "PW", "DST", "AMT"}

local lfo_val = {}
for i = 1, NUM_SLOTS do lfo_val[i] = 0 end

local mod_slot, mod_field = 1, 1
local mod_scroll = 1
local MOD_ROWS = 5

-- params currently being modulated get an asterisk on screen and in PARAMS
local marked = {}
local marks_ready = false

local function refresh_marks()
  if not marks_ready then return end
  local m = {}
  for i = 1, NUM_SLOTS do
    local d = DESTS[params:get("mod_dst_" .. i)]
    if d.id and params:get("mod_src_" .. i) > 1 and params:get("mod_amt_" .. i) ~= 0 then
      m[d.id] = true
    end
  end
  marked = m
  for _, d in ipairs(DESTS) do
    if d.id then
      params:lookup_param(d.id).name = d.pname .. (m[d.id] and " *" or "")
    end
  end
end

-- formatters ---------------------------------------------------------------

local wave_names = {"sine", "tri", "saw", "sqr"}

local function fmt_wave(p)
  local v = p:get()
  local i = math.floor(v)
  if i >= 3 or v - i < 0.05 then return wave_names[math.min(i, 3) + 1] end
  return wave_names[i + 1] .. ">" .. wave_names[i + 2]
end

local function fmt_hz(p)
  local v = p:get()
  if math.abs(v) >= 1000 then return string.format("%.1fk", v / 1000) end
  return string.format("%d", math.floor(v + 0.5))
end

local function fmt_pct(p) return string.format("%d%%", util.round(p:get() * 100)) end
local function fmt_amt(p) return string.format("%+.1f%%", p:get() * 100) end
local function fmt_sec(p) return string.format("%.2fs", p:get()) end
local function fmt_st(p) return string.format("%+dst", util.round(p:get())) end
local function fmt_oct(p) return string.format("%.1foct", p:get()) end
local function fmt_db(p) return string.format("%.0fdB", p:get()) end
local function fmt_shift(p) return string.format("%+dHz", util.round(p:get())) end

local function rate_short(v)
  if v < 1 then return (string.format("%.2f", v):gsub("^0", "")) end
  if v < 10 then return string.format("%.1f", v) end
  return string.format("%d", util.round(v))
end

-- params -------------------------------------------------------------------

local function ctl(id, name, spec, fmt)
  params:add{type = "control", id = id, name = name, controlspec = spec,
    formatter = fmt, action = function(v) engine[id](v) end}
end

local function add_params()
  params:add_separator("PANSPECTRA")

  params:add{type = "number", id = "voices", name = "voices", min = 1, max = 33,
    default = 12, action = function(v) engine.voices(v) end}
  ctl("slice_rate", "slice rate", controlspec.new(0.5, 40, "exp", 0, 12, "Hz"))
  params:add{type = "binary", id = "freeze", name = "freeze", behavior = "toggle",
    default = 0, action = function(v) engine.freeze(v) end}
  params:add{type = "trigger", id = "capture", name = "capture slice",
    action = function() engine.capture(1) end}

  params:add_separator("spectrum window")
  ctl("center", "center", controlspec.new(40, 12000, "exp", 0, 800, "Hz"), fmt_hz)
  ctl("width", "bandwidth", controlspec.new(0.1, 9, "lin", 0, 8, "oct"), fmt_oct)
  ctl("threshold", "threshold", controlspec.new(-90, -20, "lin", 0, -60, "dB"), fmt_db)
  ctl("stability", "stability", controlspec.new(0, 1, "lin", 0, 0.6), fmt_pct)
  ctl("blur", "blur", controlspec.new(0, 0.99, "lin", 0, 0), fmt_pct)

  params:add_separator("envelope")
  ctl("attack", "attack", controlspec.new(0.005, 10, "exp", 0, 0.15, "s"), fmt_sec)
  ctl("release", "release", controlspec.new(0.005, 10, "exp", 0, 0.4, "s"), fmt_sec)
  ctl("fade", "fade", controlspec.new(0.001, 10, "exp", 0, 0.3, "s"), fmt_sec)

  params:add_separator("resynthesis")
  ctl("pitch", "pitch", controlspec.new(-36, 36, "lin", 1, 0, "st", 1 / 72), fmt_st)
  ctl("shift", "freq shift", controlspec.new(-500, 500, "lin", 0, 0, "Hz", 1 / 1000), fmt_shift)
  ctl("wave", "waveform", controlspec.new(0, 3, "lin", 0, 0, "", 1 / 120), fmt_wave)
  ctl("flatten", "flatten", controlspec.new(0, 1, "lin", 0, 0), fmt_pct)
  ctl("glide", "glide", controlspec.new(0.001, 5, "exp", 0, 0.05, "s"), fmt_sec)
  ctl("spread", "stereo spread", controlspec.new(0, 1, "lin", 0, 0.7), fmt_pct)
  ctl("feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0), fmt_pct)

  params:add_separator("filter")
  params:add{type = "option", id = "filter_type", name = "filter type",
    options = {"off", "lowpass", "bandpass", "highpass"}, default = 1,
    action = function(v) engine.filter_type(v - 1) end}
  ctl("cutoff", "cutoff", controlspec.new(20, 18000, "exp", 0, 18000, "Hz"), fmt_hz)
  ctl("resonance", "resonance", controlspec.new(0, 1, "lin", 0, 0.2), fmt_pct)

  params:add_separator("levels")
  ctl("mix", "dry/wet", controlspec.new(0, 1, "lin", 0, 1), fmt_pct)
  ctl("input_gain", "input gain", controlspec.new(-24, 24, "lin", 0, 0, "dB"), fmt_db)
  ctl("level", "output level", controlspec.new(0, 1, "lin", 0, 0.5), fmt_pct)

  params:add_group("MOD MATRIX", NUM_SLOTS * 5)
  for i = 1, NUM_SLOTS do
    params:add{type = "option", id = "mod_src_" .. i, name = i .. " src",
      options = SRC_NAMES, default = 1,
      action = function(v) engine.mod_src(i, v - 1); refresh_marks() end}
    params:add{type = "control", id = "mod_rate_" .. i, name = i .. " rate",
      controlspec = controlspec.new(0.01, 20, "exp", 0, 1, "Hz"),
      action = function(v) engine.mod_rate(i, v) end}
    params:add{type = "control", id = "mod_pw_" .. i, name = i .. " pulse width",
      controlspec = controlspec.new(0.05, 0.95, "lin", 0, 0.5), formatter = fmt_pct,
      action = function(v) engine.mod_pw(i, v) end}
    params:add{type = "option", id = "mod_dst_" .. i, name = i .. " dst",
      options = DEST_NAMES, default = 1,
      action = function(v) engine.mod_dst(i, v - 1); refresh_marks() end}
    params:add{type = "control", id = "mod_amt_" .. i, name = i .. " amt",
      controlspec = controlspec.new(-1, 1, "lin", 0, 0, "", 1 / 200), formatter = fmt_amt,
      action = function(v) engine.mod_amt(i, v); refresh_marks() end}
  end
end

-- data from the engine -------------------------------------------------------

function osc.event(path, args, from)
  if path == "/panspectra/spec" then
    spectrum = args
  elseif path == "/panspectra/peaks" then
    local n = math.floor(args[1] or 0)
    local t = {}
    for i = 1, n do
      t[i] = {f = args[2 * i], a = args[2 * i + 1]}
    end
    peaks = t
  elseif path == "/panspectra/lfo" then
    for i = 1, NUM_SLOTS do lfo_val[i] = args[i] or 0 end
  end
end

-- init / cleanup -------------------------------------------------------------

function init()
  -- the engine provides its own dry path, so mute norns' input monitor
  local ok, v = pcall(function() return params:get("monitor_level") end)
  if ok and type(v) == "number" then saved_monitor = v end
  audio.level_monitor(0)

  add_params()
  marks_ready = true
  params:bang()
  refresh_marks()

  -- don't relaunch at boot: norns reloads whatever script is stored here
  norns.state.script = ""

  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
end

function cleanup()
  if saved_monitor then
    audio.level_monitor(util.dbamp(saved_monitor))
  end
end

-- controls -------------------------------------------------------------------

local function field_ok(slot, f)
  return f ~= 3 or params:get("mod_src_" .. slot) == SQUARE
end

local function mod_move(d)
  local s, f = mod_slot, mod_field
  repeat
    f = f + d
    if f > 5 then f = 1; s = s + 1 elseif f < 1 then f = 5; s = s - 1 end
  until s < 1 or s > NUM_SLOTS or field_ok(s, f)
  if s >= 1 and s <= NUM_SLOTS then mod_slot, mod_field = s, f end
end

-- hold K3 while turning for 1/10 steps on continuous params
local k3_held, k3_used = false, false

local function adjust(id, d)
  local p = params:lookup_param(id)
  if k3_held and p.controlspec then
    k3_used = true
    params:delta(id, d * 0.1)
  else
    params:delta(id, d)
  end
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, MOD_PAGE)
  elseif page == MOD_PAGE then
    if n == 2 then
      mod_move(util.clamp(d, -1, 1))
    else
      adjust(FIELD_PREFIX[mod_field] .. mod_slot, d)
      -- leaving square while the cursor sits on PW: hop back to SRC
      if not field_ok(mod_slot, mod_field) then mod_field = 1 end
    end
  else
    local e = pages[page][n - 1]
    if e then adjust(e[1], d) end
  end
end

function key(n, z)
  if n == 2 and z == 1 then
    params:set("freeze", 1 - params:get("freeze"))
  elseif n == 3 then
    if z == 1 then
      k3_held, k3_used = true, false
    else
      k3_held = false
      -- a tap (no fine adjusting while held) captures a slice
      if not k3_used then engine.capture(1) end
    end
  end
end

-- drawing ----------------------------------------------------------------------

local function fx(f)
  f = math.max(f, 1)
  return util.clamp(math.log(f / 40) / math.log(300), 0, 1) * 127
end

local function draw_main()
  -- input spectrum (pre-transpose)
  local n = #spectrum
  if n > 0 then
    local w = 128 / n
    screen.level(2)
    for i = 1, n do
      local h = math.floor(spectrum[i] * H)
      if h > 0 then
        screen.rect(math.floor((i - 1) * w), BASE - h, math.max(1, math.floor(w) - 1), h)
      end
    end
    screen.fill()
  end

  -- analysis window (knob setting)
  local c, bw = params:get("center"), params:get("width")
  local lo, hi = fx(c * 2 ^ (-bw / 2)), fx(c * 2 ^ (bw / 2))
  screen.level(5)
  screen.move(lo, BASE + 3)
  screen.line(hi, BASE + 3)
  screen.move(lo + 0.5, BASE + 1)
  screen.line(lo + 0.5, BASE + 4)
  screen.move(hi - 0.5, BASE + 1)
  screen.line(hi - 0.5, BASE + 4)
  screen.stroke()

  -- filter cutoff marker (knob setting)
  if params:get("filter_type") > 1 then
    local cx = math.floor(fx(params:get("cutoff"))) + 0.5
    screen.level(8)
    screen.move(cx, 10)
    screen.line(cx, 14)
    screen.move(cx - 2, 10)
    screen.line(cx + 3, 10)
    screen.stroke()
  end

  -- resynthesized partials (post-transpose)
  screen.level(15)
  for _, p in ipairs(peaks) do
    local x = math.floor(fx(p.f)) + 0.5
    screen.move(x, BASE)
    screen.line(x, BASE - math.max(2, p.a * H))
  end
  screen.stroke()

  -- header
  local frozen = params:get("freeze") == 1
  screen.level(4)
  screen.move(0, 7)
  screen.text(#peaks .. "/" .. params:get("voices"))
  screen.move(64, 7)
  screen.text_center(page .. "/" .. MOD_PAGE)
  screen.level(frozen and 15 or 4)
  screen.move(127, 7)
  screen.text_right(frozen and "FROZEN" or "live")

  -- page params
  local pg = pages[page]
  screen.level(15)
  local function label(e) return e[2] .. (marked[e[1]] and "*" or "") end
  screen.move(0, 63)
  screen.text(label(pg[1]) .. " " .. params:string(pg[1][1]))
  if pg[2] then
    screen.move(127, 63)
    screen.text_right(label(pg[2]) .. " " .. params:string(pg[2][1]))
  end
end

local function cell_text(i, f)
  local src = params:get("mod_src_" .. i)
  if f == 1 then return SRC_SHORT[src]
  elseif f == 2 then return rate_short(params:get("mod_rate_" .. i))
  elseif f == 3 then
    if src == SQUARE then return tostring(util.round(params:get("mod_pw_" .. i) * 100)) end
    return "-"
  elseif f == 4 then return DESTS[params:get("mod_dst_" .. i)].short
  else
    -- show tenths only when the value has them
    local v = params:get("mod_amt_" .. i) * 100
    if math.abs(v - util.round(v)) < 0.05 then return string.format("%+d", util.round(v)) end
    return string.format("%+.1f", v)
  end
end

local function draw_mod()
  if mod_slot < mod_scroll then mod_scroll = mod_slot end
  if mod_slot > mod_scroll + MOD_ROWS - 1 then mod_scroll = mod_slot - MOD_ROWS + 1 end

  -- column headers
  screen.level(4)
  screen.move(0, 7)
  screen.text("#")
  for f = 1, 4 do
    screen.move(FIELD_X[f], 7)
    screen.text(FIELD_HEAD[f])
  end
  screen.move(127, 7)
  screen.text_right(FIELD_HEAD[5])
  screen.level(1)
  screen.rect(0, 9, 128, 1)
  screen.fill()

  for r = 0, MOD_ROWS - 1 do
    local i = mod_scroll + r
    local y = 17 + r * 9
    local active = params:get("mod_src_" .. i) > 1

    -- slot number pulses with its lfo (values come from the engine)
    screen.level(active and util.clamp(math.floor(4 + (lfo_val[i] + 1) * 5.5), 1, 15) or 2)
    screen.move(0, y)
    screen.text(i)

    for f = 1, 5 do
      local txt = cell_text(i, f)
      local w = screen.text_extents(txt)
      local x = (f == 5) and (127 - w) or FIELD_X[f]
      if i == mod_slot and f == mod_field then
        screen.level(15)
        screen.rect(x - 1, y - 6, w + 2, 8)
        screen.fill()
        screen.level(0)
      else
        screen.level(active and 10 or 3)
      end
      screen.move(x, y)
      screen.text(txt)
    end
  end

  -- footer: full description of the selected slot's destination
  local d = DESTS[params:get("mod_dst_" .. mod_slot)]
  screen.level(1)
  screen.rect(0, 56, 128, 1)
  screen.fill()
  screen.level(6)
  screen.move(0, 63)
  screen.text(mod_slot .. " > " .. d.name)
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_size(8)
  if page == MOD_PAGE then draw_mod() else draw_main() end
  screen.update()
end
