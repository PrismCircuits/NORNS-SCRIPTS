-- panspectra
-- spectral resynthesis
--
-- E1 page
-- E2 / E3 adjust
-- K2 freeze
-- K3 capture slice (frozen)

engine.name = "PanSpectra"

local spectrum = {}
local peaks = {}
local spec_target = {}
local prev_peaks = {}
local peak_fade = 1
local page = 1
local last_snap = 0

local function capture()
  engine.capture(1)
  last_snap = util.time()
end

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
  {{"cutoff", "cut"}, {"resonance", "res"}},
  {{"filter_type", "type"}},
}

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
    action = function() capture() end}

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

  params:add_separator("filter")
  params:add{type = "option", id = "filter_type", name = "filter type",
    options = {"lowpass", "bandpass", "highpass"}, default = 1,
    action = function(v) engine.filter_type(v - 1) end}
  ctl("cutoff", "cutoff", controlspec.new(20, 20000, "exp", 0, 20000, "Hz"),
    fmt_hz, function(v) engine.cutoff(v) end)
  ctl("resonance", "resonance", controlspec.new(0, 1, "lin", 0, 0),
    fmt_pct, function(v) engine.resonance(v) end)

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
    spec_target = args
    if params:get("freeze") == 0 then spectrum = args end
  elseif path == "/panspectra/peaks" then
    local n = math.floor(args[1] or 0)
    local t = {}
    for i = 1, n do
      t[i] = {f = args[2 * i], a = args[2 * i + 1]}
    end
    if params:get("freeze") == 1 then
      prev_peaks = peak_fade < 0.5 and prev_peaks or peaks
      peak_fade = 0
    end
    peaks = t
  end
end

local function morph_display(dt)
  local mt = 0
  if params:get("freeze") == 1 then
    local b = params:get("blur")
    mt = b * b * 8
  end
  if mt < 0.05 then
    spectrum = spec_target
    peak_fade = 1
    prev_peaks = {}
    return
  end
  local a = 1 - math.exp(-dt * 6.9 / mt)
  local nxt = {}
  for i = 1, #spec_target do
    local cur = spectrum[i] or 0
    nxt[i] = cur + (spec_target[i] - cur) * a
  end
  spectrum = nxt
  peak_fade = peak_fade + (1 - peak_fade) * a
  if peak_fade > 0.99 then
    peak_fade = 1
    prev_peaks = {}
  end
end

local function each_peak(fn)
  for _, pk in ipairs(prev_peaks) do fn(pk, 1 - peak_fade) end
  for _, pk in ipairs(peaks) do fn(pk, peak_fade) end
end

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
      capture()
    end
  end
end

-- ui -----------------------------------------------------------------------

-- the engine provides its own dry path, so mute norns' input monitor
-- while the script runs (otherwise dry would leak through at 100% wet)
local saved_monitor = nil

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
  else
    local e = pages[page][n - 1]
    if e then params:delta(pid(e), d) end
  end
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    params:set("freeze", 1 - params:get("freeze"))
  elseif n == 3 then
    capture()
  end
end

local g = grid.connect()
local grid_view = "spectrum"
local grid_page = 1
local menu_held = false
local menu_chose = false
local popup, popup_time = nil, 0

local grid_pages = {
  {"voices", "slice_rate", "freeze", "capture"},
  {"center", "width", "threshold", "stability", "blur"},
  {"pitch", "shift", "wave", "flatten", "glide"},
  {"spread", "feedback", "mix", "input_gain", "level"},
  {"snap_mode", function()
    return params:get("snap_mode") == 3 and "snap_div" or "snap_rate"
  end, "snap_chance"},
  {"filter_type", "cutoff", "resonance"},
}

local function gid(e)
  return type(e) == "function" and e() or e
end

local function get_raw(id, p)
  if p.t == params.tCONTROL then return params:get_raw(id) end
  if p.t == params.tNUMBER then
    return (params:get(id) - p.min) / math.max(p.max - p.min, 1)
  end
  return 0
end

local function set_raw(id, p, r)
  if p.t == params.tCONTROL then
    params:set_raw(id, r)
  elseif p.t == params.tNUMBER then
    params:set(id, util.round(p.min + r * (p.max - p.min)))
  end
end

local function show_popup(id)
  popup = params:lookup_param(id).name .. " " .. params:string(id)
  popup_time = util.time()
end

local function grid_key(x, y, z)
  if x == 1 and y == 8 then
    if z == 1 then
      menu_held = true
      menu_chose = false
    else
      menu_held = false
      grid_view = menu_chose and "edit" or "spectrum"
    end
    return
  end

  if not (menu_held or grid_view == "edit") or z == 0 then return end

  if y == 8 then
    if x <= #grid_pages + 1 then
      grid_page = x - 1
      menu_chose = true
    end
    return
  end

  local e = grid_pages[grid_page][y]
  if not e then return end
  local id = gid(e)
  local p = params:lookup_param(id)
  menu_chose = true

  if p.t == params.tTRIGGER then
    p:bang()
  elseif p.t == params.tBINARY then
    params:set(id, 1 - params:get(id))
  elseif p.t == params.tOPTION then
    if x <= p.count then params:set(id, x) end
  elseif x == 15 then
    params:delta(id, -1)
  elseif x == 16 then
    params:delta(id, 1)
  else
    set_raw(id, p, (x - 1) / 13)
  end
  show_popup(id)
end

local function grid_spectrum()
  local n = #spectrum
  if n > 0 then
    for col = 1, 16 do
      local v = 0
      for i = math.floor((col - 1) * n / 16) + 1, math.floor(col * n / 16) do
        v = math.max(v, spectrum[i] or 0)
      end
      local h = v * 8
      for k = 1, 8 do
        local lvl = 0
        if h >= k then
          lvl = 2 + k
        elseif h > k - 1 then
          lvl = math.floor((h - (k - 1)) * (2 + k))
        end
        if lvl > 0 then g:led(col, 9 - k, lvl) end
      end
    end
  end

  each_peak(function(pk, w)
    local lvl = math.floor(w * 15 + 0.5)
    if lvl > 0 then
      local f = math.max(pk.f, 1)
      local pos = util.clamp(math.log(f / 40) / math.log(300), 0, 1)
      local col = util.clamp(math.floor(pos * 16) + 1, 1, 16)
      local row = util.clamp(math.ceil(pk.a * 8), 1, 8)
      g:led(col, 9 - row, lvl)
    end
  end)
end

local function grid_editor()
  for y, e in ipairs(grid_pages[grid_page]) do
    local id = gid(e)
    local p = params:lookup_param(id)
    if p.t == params.tTRIGGER then
      g:led(1, y, util.time() - last_snap < 0.1 and 15 or 3)
    elseif p.t == params.tBINARY then
      g:led(1, y, params:get(id) == 1 and 15 or 3)
    elseif p.t == params.tOPTION then
      for x = 1, p.count do
        g:led(x, y, params:get(id) == x and 15 or 3)
      end
    else
      local pos = util.round(get_raw(id, p) * 13) + 1
      for x = 1, 14 do
        g:led(x, y, x < pos and 5 or (x == pos and 15 or 1))
      end
      g:led(15, y, 3)
      g:led(16, y, 3)
    end
  end

  g:led(1, 8, menu_held and 15 or 6)
  for i = 1, #grid_pages do
    g:led(i + 1, 8, i == grid_page and 15 or 4)
  end
end

local function grid_redraw()
  g:all(0)
  if menu_held or grid_view == "edit" then
    grid_editor()
  else
    grid_spectrum()
  end
  g:refresh()
end

function init()
  local ok, v = pcall(function() return params:get("monitor_level") end)
  if ok and type(v) == "number" then saved_monitor = v end
  audio.level_monitor(0)

  add_params()
  params:bang()
  g.key = grid_key
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      morph_display(1 / 15)
      redraw()
      grid_redraw()
    end
  end)
  clock.run(snap_loop)
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
  each_peak(function(p, w)
    local lvl = math.floor(w * 15 + 0.5)
    if lvl > 0 then
      local x = math.floor(fx(p.f)) + 0.5
      screen.level(lvl)
      screen.move(x, BASE)
      screen.line(x, BASE - math.max(2, p.a * H))
      screen.stroke()
    end
  end)

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
  if popup and util.time() - popup_time < 1.5 then
    screen.move(64, 63)
    screen.text_center(popup)
  else
    screen.move(0, 63)
    screen.text(pg[1][2] .. " " .. params:string(pid(pg[1])))
    if pg[2] then
      screen.move(127, 63)
      screen.text_right(pg[2][2] .. " " .. params:string(pid(pg[2])))
    end
  end

  screen.update()
end

function cleanup()
  if saved_monitor then
    audio.level_monitor(util.dbamp(saved_monitor))
  end
end

