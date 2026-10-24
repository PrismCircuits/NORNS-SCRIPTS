-- panspectra
-- spectral resynthesis
--
-- E1 page
-- E2 / E3 adjust
-- K2 freeze
-- K3 capture slice (frozen)
-- page 9: auto snap while frozen

engine.name = "PanSpectra"

local spectrum = {}
local peaks = {}
local page = 1
local last_snap = 0

local BASE = 50
local H = 36

local pages = {
  {{"voices", "vox"}, {"slice_rate", "rate"}},
  {{"center", "ctr"}, {"width", "bw"}},
  {{"stability", "lock"}, {"threshold", "thresh"}},
  {{"pitch", "pitch"}, {"shift", "shift"}},
  {{"wave", "wave"}, {"flatten", "flat"}},
  {{"glide", "glide"}, {"blur", "blur"}},
  {{"feedback", "fdbk"}, {"spread", "spread"}},
  {{"mix", "mix"}, {"level", "level"}},
  {{"snap_mode", "snap"}, {function()
    return params:get("snap_mode") == 3 and "snap_div" or "snap_rate"
  end, "rate"}},
}

-- a page entry's param id may be a function (rate follows snap mode)
local function pid(e)
  return type(e[1]) == "function" and e[1]() or e[1]
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

local function fmt_pct(p) return string.format("%d%%", math.floor(p:get() * 100 + 0.5)) end
local function fmt_sec(p) return string.format("%.2fs", p:get()) end
local function fmt_st(p) return string.format("%+dst", math.floor(p:get() + 0.5)) end
local function fmt_oct(p) return string.format("%.1foct", p:get()) end
local function fmt_db(p) return string.format("%.0fdB", p:get()) end
local function fmt_shift(p) return string.format("%+dHz", math.floor(p:get() + 0.5)) end

local snap_div_names = {"4 bars", "2 bars", "1 bar", "1/2", "1/4", "1/8", "1/16"}
local snap_div_beats = {16, 8, 4, 2, 1, 1 / 2, 1 / 4}

local function ctl(id, name, spec, fmt, action)
  params:add{type = "control", id = id, name = name, controlspec = spec,
    formatter = fmt, action = action}
end

-- params -------------------------------------------------------------------

local function add_params()
  params:add_separator("PANSPECTRA")

  params:add{type = "number", id = "voices", name = "voices", min = 1, max = 33,
    default = 12, action = function(v) engine.voices(v) end}
  ctl("slice_rate", "slice rate", controlspec.new(0.5, 40, "exp", 0, 12, "Hz"),
    nil, function(v) engine.slice_rate(v) end)
  params:add{type = "binary", id = "freeze", name = "freeze", behavior = "toggle",
    default = 0, action = function(v) engine.freeze(v) end}
  params:add{type = "trigger", id = "capture", name = "capture slice",
    action = function() engine.capture(1) end}

  params:add_separator("auto snap")
  params:add{type = "option", id = "snap_mode", name = "snap mode",
    options = {"off", "free", "sync"}, default = 1}
  ctl("snap_rate", "snap rate", controlspec.new(0.1, 20, "exp", 0, 1, "Hz"),
    function(p) return string.format("%.2fHz", p:get()) end)
  params:add{type = "option", id = "snap_div", name = "snap division",
    options = snap_div_names, default = 5}
  ctl("snap_chance", "snap chance", controlspec.new(0, 1, "lin", 0, 1),
    fmt_pct)

  params:add_separator("spectrum window")
  ctl("center", "center", controlspec.new(40, 12000, "exp", 0, 800, "Hz"),
    fmt_hz, function(v) engine.center(v) end)
  ctl("width", "bandwidth", controlspec.new(0.1, 9, "lin", 0, 8, "oct"),
    fmt_oct, function(v) engine.width(v) end)
  ctl("threshold", "threshold", controlspec.new(-90, -20, "lin", 0, -60, "dB"),
    fmt_db, function(v) engine.threshold(v) end)
  ctl("stability", "stability", controlspec.new(0, 1, "lin", 0, 0.6),
    fmt_pct, function(v) engine.stability(v) end)
  -- when frozen, blur is the morph time between frozen states
  ctl("blur", "blur", controlspec.new(0, 0.99, "lin", 0, 0),
    function(p)
      if params:get("freeze") == 1 then
        local v = p:get()
        return string.format("%.1fs", v * v * 8)
      end
      return fmt_pct(p)
    end, function(v) engine.blur(v) end)

  params:add_separator("resynthesis")
  ctl("pitch", "pitch", controlspec.new(-36, 36, "lin", 1, 0, "st", 1 / 72),
    fmt_st, function(v) engine.pitch(v) end)
  ctl("shift", "freq shift", controlspec.new(-500, 500, "lin", 0, 0, "Hz", 1 / 1000),
    fmt_shift, function(v) engine.shift(v) end)
  ctl("wave", "waveform", controlspec.new(0, 3, "lin", 0, 0, "", 1 / 120),
    fmt_wave, function(v) engine.wave(v) end)
  ctl("flatten", "flatten", controlspec.new(0, 1, "lin", 0, 0),
    fmt_pct, function(v) engine.flatten(v) end)
  ctl("glide", "glide", controlspec.new(0.001, 5, "exp", 0, 0.05, "s"),
    fmt_sec, function(v) engine.glide(v) end)
  ctl("spread", "stereo spread", controlspec.new(0, 1, "lin", 0, 0.7),
    fmt_pct, function(v) engine.spread(v) end)
  ctl("feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0),
    fmt_pct, function(v) engine.feedback(v) end)

  params:add_separator("levels")
  ctl("mix", "dry/wet", controlspec.new(0, 1, "lin", 0, 1),
    fmt_pct, function(v) engine.mix(v) end)
  ctl("input_gain", "input gain", controlspec.new(-24, 24, "lin", 0, 0, "dB"),
    fmt_db, function(v) engine.input_gain(v) end)
  ctl("level", "output level", controlspec.new(0, 1, "lin", 0, 0.5),
    fmt_pct, function(v) engine.level(v) end)
end

-- analysis data from the engine ---------------------------------------------

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
  end
end

-- auto snap ----------------------------------------------------------------

-- while frozen, periodically capture a new slice (free-running Hz or
-- synced to the norns clock), each tick passing a chance roll
local function snap_loop()
  while true do
    local mode = params:get("snap_mode")
    if mode == 2 then
      clock.sleep(1 / params:get("snap_rate"))
    elseif mode == 3 then
      clock.sync(snap_div_beats[params:get("snap_div")])
    else
      clock.sleep(0.05)
    end
    if mode > 1 and params:get("snap_mode") > 1 and params:get("freeze") == 1
      and math.random() < params:get("snap_chance") then
      engine.capture(1)
      last_snap = util.time()
    end
  end
end

-- ui -----------------------------------------------------------------------

-- the engine provides its own dry path, so mute norns' input monitor
-- while the script runs (otherwise dry would leak through at 100% wet)
local saved_monitor = nil

function init()
  local ok, v = pcall(function() return params:get("monitor_level") end)
  if ok and type(v) == "number" then saved_monitor = v end
  audio.level_monitor(0)

  add_params()
  params:bang()
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
  clock.run(snap_loop)
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
  else
    params:delta(pid(pages[page][n - 1]), d)
  end
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    params:set("freeze", 1 - params:get("freeze"))
  elseif n == 3 then
    engine.capture(1)
    last_snap = util.time()
  end
end

local function fx(f)
  f = math.max(f, 1)
  return util.clamp(math.log(f / 40) / math.log(300), 0, 1) * 127
end

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_size(8)

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

  -- analysis window
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
  screen.text_center(page .. "/" .. #pages)
  screen.level(frozen and 15 or 4)
  screen.move(127, 7)
  screen.text_right(frozen and "FROZEN" or "live")
  if frozen and util.time() - last_snap < 0.1 then
    screen.rect(91, 2, 3, 3)
    screen.fill()
  end

  -- page params
  local pg = pages[page]
  screen.level(15)
  screen.move(0, 63)
  screen.text(pg[1][2] .. " " .. params:string(pid(pg[1])))
  screen.move(127, 63)
  screen.text_right(pg[2][2] .. " " .. params:string(pid(pg[2])))

  screen.update()
end

function cleanup()
  if saved_monitor then
    audio.level_monitor(util.dbamp(saved_monitor))
  end
end

