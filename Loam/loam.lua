-- loam
-- 8-track synthesis groovebox
--
-- every track can be any engine:
-- kick snare clap hat tom rim
-- cowbell synth fm sample
--
-- E1: page (master, tracks 1-8)
-- K2: next tab   K1+K2: play/stop
-- K3: action (toggle step,
--     audition, load sample, mute)
-- K1 = shift (fine adjust)
-- K1+K3 on TRK tab: clear track
-- K1+K3 on MASTER: clear all
--
-- grid: the selected track's
-- 128 steps. hold step 1 + press
-- a step to set the loop end.
-- hold a step + turn E2/E3 to
-- lock parameters on that step.

engine.name = 'Loam'

local S = include('lib/specs')
local D = include('lib/draw')
local fileselect = require 'fileselect'

local NT, NS = 8, 128
local TABS = {"SEQ", "SND", "FX", "TRK"}

local tracks = {}
local playing, pending_start = false, false
local tick_n, last_abs, last_bs = 0, nil, 0
local master_flash = 0

local page = 1        -- 0 = master, 1..8 = track pages
local sel = 1         -- track shown on the grid
local cur_tab = 1     -- current track tab (SEQ/SND/FX/TRK), shared by all tracks
local mtab = 1        -- master tab: 1 MIX, 2 FX
local mix_sel = 1
local ksel = {}       -- selected knob per context
local cursor = 1      -- SEQ cursor
local shift = false
local lock = nil      -- {t, i, src}: step whose parameters are being locked
local lsel = 1
local touched = {key = nil, at = 0} -- knob last turned: its value shows briefly
local SHOW_VALUE_SECS = 1.0
local function touch(key) touched.key = key; touched.at = util.time() end
local function showing_value(key) return touched.key == key and util.time() - touched.at < SHOW_VALUE_SECS end
local browsing = false -- file browser is open: don't draw over it
local ready = false    -- set after init's params:bang(), so startup doesn't load samples twice
local confirm = nil   -- {msg, fn}: pending yes/no question (K3 yes, K2 no)
local held = {}       -- held grid keys
local grid_dirty = true
local g = grid.connect()

local function tid(t, k) return "t" .. t .. "_" .. k end
local function eng(t) return S.ENGINES[params:get(tid(t, "engine"))] end
local function rate_ticks(t) return S.RATES[params:get(tid(t, "rate"))][2] end

local function blank_steps()
  local s = {}
  for i = 1, NS do s[i] = {on = false, locks = {}} end
  return s
end

-- ===================================================================== sound

local function update_delay()
  local beats = S.DELAY_TIMES[params:get("m_dtime")][2]
  engine.mfx("dtime", math.min(2, beats * clock.get_beat_sec()))
end

local function lock_value(t, i, k)
  local L = tracks[t].steps[i].locks
  if L[k] ~= nil then return L[k], true end
  if k == "vel" then return 100, false end
  if k == "prob" then return params:get(tid(t, "prob")), false end
  return params:get(tid(t, k)), false
end

-- play step i of track t (i = nil for an audition with the base sound)
local function fire(t, i, audition)
  local tr = tracks[t]
  local step = i and tr.steps[i]
  local L = step and step.locks or {}
  if not audition then
    if not step.on then return end
    if params:get(tid(t, "mute")) == 2 then return end
    local prob = L.prob or params:get(tid(t, "prob"))
    if prob < 100 and math.random(100) > prob then return end
  end
  local dur = params:get(tid(t, "gate")) * rate_ticks(t) / 96 * clock.get_beat_sec()
  local vel = (L.vel or 100) / 100
  local locked = false
  for k, v in pairs(L) do
    local sp = S.BY_KEY[k]
    if sp then engine.ps(t, k, S.to_sc(sp, v)); locked = true end
  end
  engine.trig(t, vel, dur, params:get(tid(t, "choke")) - 1)
  if locked then
    for k in pairs(L) do
      local sp = S.BY_KEY[k]
      if sp then engine.ps(t, k, S.to_sc(sp, params:get(tid(t, k)))) end
    end
  end
  tr.flash = 4
end

-- ===================================================================== sequencer

local function reset_positions(n)
  for t = 1, NT do
    tracks[t].pos = 0
    tracks[t].anchor = n
  end
end

local function on_tick(n)
  local ml = params:get("m_mlen")
  if ml > 0 and n > 0 and n % (ml * 24) == 0 then
    reset_positions(n)
    master_flash = 4
  end
  if n % 96 == 0 then
    local bs = clock.get_beat_sec()
    if bs ~= last_bs then last_bs = bs; update_delay() end
  end
  for t = 1, NT do
    local tr = tracks[t]
    if (n - tr.anchor) % rate_ticks(t) == 0 then
      tr.pos = tr.pos + 1
      if tr.pos > params:get(tid(t, "len")) then tr.pos = 1 end
      fire(t, tr.pos, false)
    end
  end
end

local function process(abs)
  if pending_start and abs % 96 == 0 then
    pending_start = false
    playing = true
    tick_n = 0
    reset_positions(0)
  elseif playing then
    tick_n = tick_n + 1
  end
  if playing then on_tick(tick_n) end
end

local function tick_loop()
  while true do
    clock.sync(1 / 96)
    local now = math.floor(clock.get_beats() * 96 + 0.5)
    if last_abs == nil then last_abs = now - 1 end
    local n = util.clamp(now - last_abs, 0, 8)
    for k = now - n + 1, now do process(k) end
    last_abs = now
  end
end

local function start() if not playing then pending_start = true end end
local function stop()
  playing, pending_start = false, false
  reset_positions(0)
end
function clock.transport.start() start() end
function clock.transport.stop() stop() end

-- ===================================================================== params

local function add_param(id, sp, action, name)
  local nm = name or sp.n
  if sp.t == "ctl" then
    params:add{type = "control", id = id, name = nm, controlspec = sp.cs,
      formatter = function(p) return S.fmt(sp, p:get()) end, action = action}
  elseif sp.t == "int" then
    params:add{type = "number", id = id, name = nm, min = sp.min, max = sp.max, default = sp.def,
      formatter = function(p) return S.fmt(sp, p:get()) end, action = action}
  else
    params:add{type = "option", id = id, name = nm, options = sp.opts, default = sp.def, action = action}
  end
end

local function update_visibility(t)
  if not params.hide then return end
  local cur = params:get(tid(t, "engine"))
  for i, e in ipairs(S.ENGINES) do
    for _, p in ipairs(e.params) do
      if i == cur then params:show(tid(t, p.k)) else params:hide(tid(t, p.k)) end
    end
  end
  if S.ENGINES[cur].id == "sample" then params:show(tid(t, "file")) else params:hide(tid(t, "file")) end
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

local function load_sample(t, path)
  if path and path ~= "" and not path:match("/$") and util.file_exists(path) then
    tracks[t].file = path:match("[^/]+$")
    engine.sload(t, path)
  else
    tracks[t].file = nil
    engine.sclear(t)
  end
end

local function add_params()
  params:add_separator("LOAM")
  params:add_group("MASTER", #S.MASTER)
  for _, sp in ipairs(S.MASTER) do
    add_param("m_" .. sp.k, sp, function(v)
      if sp.k == "dtime" then update_delay()
      elseif sp.k ~= "mlen" then engine.mfx(sp.k, S.to_sc(sp, v)) end
    end)
  end

  local nengine = 0
  for _, e in ipairs(S.ENGINES) do nengine = nengine + #e.params end

  for t = 1, NT do
    params:add_group("TRACK " .. t, #S.TRK + #S.FX + 1 + nengine)
    for _, sp in ipairs(S.TRK) do
      local action
      if sp.k == "engine" then
        action = function(v) engine.voice(t, S.ENGINES[v].def); update_visibility(t) end
      elseif sp.k == "mute" then
        action = function(v) engine.fx(t, "mute", v - 1) end
      end
      add_param(tid(t, sp.k), sp, action)
    end
    params:add_file(tid(t, "file"), "SAMPLE FILE", _path.audio)
    params:set_action(tid(t, "file"), function(path) load_sample(t, path) end)
    for _, sp in ipairs(S.FX) do
      add_param(tid(t, sp.k), sp, function(v) engine.fx(t, sp.k, S.to_sc(sp, v)) end)
    end
    for _, e in ipairs(S.ENGINES) do
      for _, sp in ipairs(e.params) do
        local action = function(v) engine.p(t, sp.k, S.to_sc(sp, v)) end
        if sp.k == "smp_norm" then
          -- normalizing happens when a file is read, so reload the track's sample when it's switched
          action = function(v)
            engine.p(t, sp.k, S.to_sc(sp, v))
            if ready and tracks[t].file then load_sample(t, params:get(tid(t, "file"))) end
          end
        end
        add_param(tid(t, sp.k), sp, action, e.name .. " " .. sp.n)
      end
    end
  end
end

-- ===================================================================== patterns

local function pattern_data()
  local d = {}
  for t = 1, NT do
    d[t] = {}
    for i = 1, NS do
      local s = tracks[t].steps[i]
      if s.on or next(s.locks) then d[t][i] = {on = s.on, locks = s.locks} end
    end
  end
  return d
end

local function clear_track(t)
  tracks[t].steps = blank_steps()
  if lock and lock.t == t then lock = nil end
  grid_dirty = true
end

local function clear_all()
  for t = 1, NT do clear_track(t) end
end

local function load_pattern(d)
  for t = 1, NT do
    tracks[t].steps = blank_steps()
    for i = 1, NS do
      local s = d[t] and d[t][i]
      if s then
        tracks[t].steps[i].on = s.on and true or false
        tracks[t].steps[i].locks = s.locks or {}
      end
    end
  end
end

-- starting sounds for each track (no steps: the pattern always starts empty)
local function default_kit()
  local function set(t, k, v) params:set(tid(t, k), v) end
  -- 1 kick
  set(1, "engine", S.ENGINE_INDEX.kick)
  -- 2 snare
  set(2, "engine", S.ENGINE_INDEX.snare); set(2, "rev", 0.15)
  -- 3 clap
  set(3, "engine", S.ENGINE_INDEX.clap); set(3, "rev", 0.25)
  -- 4 closed hat (choke A)
  set(4, "engine", S.ENGINE_INDEX.hat); set(4, "choke", 3); set(4, "level", 0.55); set(4, "pan", 0.2)
  -- 5 open hat (choke A)
  set(5, "engine", S.ENGINE_INDEX.hat); set(5, "choke", 3); set(5, "hat_decay", 0.45)
  set(5, "level", 0.45); set(5, "pan", -0.2)
  -- 6 mono bass synth
  set(6, "engine", S.ENGINE_INDEX.synth); set(6, "choke", 2); set(6, "gate", 0.8)
  set(6, "synth_cutoff", 450); set(6, "synth_res", 0.5); set(6, "synth_fenv", 0.6); set(6, "level", 0.6)
  -- 7 fm bells
  set(7, "engine", S.ENGINE_INDEX.fm)
  set(7, "fm_ratio", 3.5); set(7, "fm_index", 3); set(7, "fm_decay", 1.2)
  set(7, "dly", 0.4); set(7, "rev", 0.3); set(7, "level", 0.4); set(7, "pan", -0.3)
  -- 8 sample slot
  set(8, "engine", S.ENGINE_INDEX.sample)
end

-- ===================================================================== knob lists

local function lock_list(t)
  local l = {}
  for _, sp in ipairs(S.STEP) do l[#l + 1] = {k = sp.k, sp = sp} end
  for _, sp in ipairs(eng(t).params) do l[#l + 1] = {k = sp.k, sp = sp} end
  return l
end

local MASTER_LIST
local function master_list()
  if MASTER_LIST then return MASTER_LIST end
  local l = {{id = "clock_tempo", sp = S.TEMPO}}
  local by = {}
  for _, sp in ipairs(S.MASTER) do by[sp.k] = sp end
  l[#l + 1] = {id = "m_mlen", sp = by.mlen}
  l[#l + 1] = {id = "m_vol", sp = by.vol}
  for _, sp in ipairs(S.MASTER) do
    if sp.k ~= "mlen" and sp.k ~= "vol" then l[#l + 1] = {id = "m_" .. sp.k, sp = sp} end
  end
  MASTER_LIST = l
  return l
end

local function knob_context()
  if lock then return "lock", lock_list(lock.t) end
  if page == 0 then return "master", master_list() end
  local t, tb = page, cur_tab
  local l = {}
  local src = tb == 2 and eng(t).params or tb == 3 and S.FX or S.TRK
  for _, sp in ipairs(src) do l[#l + 1] = {id = tid(t, sp.k), sp = sp} end
  return (tb == 2 and eng(t).id or TABS[tb]), l  -- knob choice follows you across tracks
end

-- ===================================================================== screen

local function header(title, tabs, active, flash)
  local w = screen.text_extents(title)
  if flash then
    screen.level(15); screen.rect(0, 0, w + 2, 8); screen.fill(); screen.level(0)
  else
    screen.level(15)
  end
  screen.move(1, 6); screen.text(title)
  local x = w + 6
  if playing then
    screen.level(15); screen.move(x, 1); screen.line(x + 4, 3.5); screen.line(x, 6); screen.close(); screen.fill()
  else
    screen.level(pending_start and 8 or 3); screen.rect(x, 1, 4, 5); screen.fill()
  end
  if master_flash > 0 then screen.level(15); screen.rect(x + 7, 2, 2, 2); screen.fill() end
  x = 128
  for i = #tabs, 1, -1 do
    local tw = screen.text_extents(tabs[i])
    x = x - tw
    screen.level(i == active and 15 or 3)
    screen.move(x, 6); screen.text(tabs[i])
    x = x - 5
  end
end

local function draw_knobs(list, idx, getter)
  local pg = math.floor((idx - 1) / 4)
  local npg = math.ceil(#list / 4)
  for j = 1, 4 do
    local n = pg * 4 + j
    local e = list[n]
    if e then
      local v, locked = getter(e)
      local s = n == idx
      local text = (s and showing_value(e.id or ("lock:" .. e.k))) and S.fmt(e.sp, v) or e.sp.n
      D.knob(16 + (j - 1) * 32, 44, 8, S.norm(e.sp, v), text, s, e.sp.bi, locked)
    end
  end
  if npg > 1 then
    for p = 1, npg do
      screen.level(p == pg + 1 and 15 or 2)
      screen.rect(64 - npg * 3 + (p - 1) * 6, 33, 4, 1); screen.fill()
    end
  end
end

local function draw_seq(t)
  local tr = tracks[t]
  local e = eng(t)
  local len = params:get(tid(t, "len"))
  local glyph = D.glyph[e.id]
  for i = 1, NS do
    local col, row = (i - 1) % 16, math.floor((i - 1) / 16)
    local x, y = col * 8, 9 + row * 6
    local st = tr.steps[i]
    if st.on then
      local vel = st.locks.vel or 100
      screen.level(i <= len and (4 + math.floor(vel / 100 * 11)) or 1)
      glyph(x, y, st.locks.synth_note or st.locks.fm_note or params:get(tid(t, "synth_note")))
      if next(st.locks) and i <= len then
        screen.level(15); screen.pixel(x + 6, y); screen.fill()
      end
    elseif i <= len then
      screen.level(col % 4 == 0 and 5 or 2)
      screen.pixel(x + 3, y + 2); screen.fill()
    end
    if playing and i == tr.pos then
      screen.level(15); screen.rect(x, y + 5, 7, 1); screen.fill()
    end
    if i == cursor then
      screen.level(lock and 15 or 9)
      screen.rect(x - 0.5, y - 0.5, 8, 6); screen.stroke()
    end
  end
  screen.level(4); screen.move(1, 63)
  local L = tr.steps[cursor].locks
  local nl = 0
  for _ in pairs(L) do nl = nl + 1 end
  screen.text(string.format("S%d  LEN %d  %s  P%d%%", cursor, len, S.RATES[params:get(tid(t, "rate"))][1],
    L.prob or params:get(tid(t, "prob"))))
  if nl > 0 then screen.move(127, 63); screen.level(15); screen.text_right(nl .. " LOCK") end
end

local function fx_vis(t)
  local function p(k) return params:get(tid(t, k)) end
  local drive, bits, srate, filt, pan = p("drive"), p("bits"), p("srate"), p("filter"), p("pan")
  -- drive transfer curve
  screen.level(3); screen.rect(0.5, 11.5, 22, 20); screen.stroke()
  screen.level(15)
  for i = 0, 22 do
    local x = i / 22 * 2 - 1
    local y = x * (1 - drive) + math.tanh(x * (1 + drive * 20)) * 0.7 * drive
    if i == 0 then screen.move(i + 0.5, 21.5 - y * 9) else screen.line(i + 0.5, 21.5 - y * 9) end
  end
  screen.stroke()
  -- bit / rate crush staircase
  local hs = util.linlin(math.log(400), math.log(48000), 6, 1, math.log(srate))
  local q = util.linlin(2, 16, 1.5, 10, bits)
  screen.level(10)
  for i = 0, 28 do
    local hx = math.floor(i / hs) * hs
    local y = math.floor(math.sin(hx / 28 * 2 * math.pi) * q + 0.5) / q
    if i == 0 then screen.move(28 + i, 21 - y * 9) else screen.line(28 + i, 21 - y * 9) end
  end
  screen.stroke()
  -- dj filter
  screen.level(12)
  for i = 0, 28 do
    local pos = i / 28
    local y = 1
    if filt < -0.01 then y = util.clamp(((1 + filt) - pos) * 3 + 1, 0, 1) end
    if filt > 0.01 then y = util.clamp((pos - filt) * 3 + 1, 0, 1) end
    if i == 0 then screen.move(62 + i, 30 - y * 17) else screen.line(62 + i, 30 - y * 17) end
  end
  screen.stroke()
  -- pan + sends
  screen.level(3); screen.move(96, 15); screen.line(127, 15); screen.stroke()
  screen.level(15); screen.circle(111.5 + pan * 15, 15, 2); screen.fill()
  screen.level(10)
  screen.rect(96, 22, 31 * p("dly"), 2); screen.fill()
  screen.rect(96, 27, 31 * p("rev"), 2); screen.fill()
  screen.level(3)
  screen.rect(96, 22, 31, 2); screen.stroke()
  screen.rect(96, 27, 31, 2); screen.stroke()
end

local function trk_vis(t)
  local tr = tracks[t]
  local len = params:get(tid(t, "len"))
  screen.level(2); screen.rect(0, 13, len, 8); screen.fill()
  for i = 1, NS do
    if tr.steps[i].on then
      screen.level(i <= len and 15 or 4)
      screen.move(i - 0.5, 14); screen.line(i - 0.5, 20); screen.stroke()
    end
  end
  if playing and tr.pos > 0 then
    screen.level(8); screen.move(tr.pos - 0.5, 11); screen.line(tr.pos - 0.5, 23); screen.stroke()
  end
  screen.level(6); screen.move(1, 30)
  screen.text(string.format("%d/128  %s  P%d%%  CHOKE %s", len, S.RATES[params:get(tid(t, "rate"))][1],
    params:get(tid(t, "prob")), S.CHOKES[params:get(tid(t, "choke"))]))
end

local function clamp_sel(ctx, list)
  ksel[ctx] = util.clamp(ksel[ctx] or 1, 1, #list)
  return ksel[ctx]
end

local function draw_mixer()
  for t = 1, NT do
    local x = (t - 1) * 16
    local tr = tracks[t]
    if t == mix_sel then screen.level(1); screen.rect(x, 9, 16, 55); screen.fill() end
    if tr.flash > 0 then
      screen.level(15); screen.rect(x + 3, 10, 10, 7); screen.fill(); screen.level(0)
    else
      screen.level(t == mix_sel and 15 or 6)
    end
    screen.move(x + 8, 16); screen.text_center(t)
    screen.level(4); screen.move(x + 8, 23); screen.text_center(eng(t).abbr)
    local pan = params:get(tid(t, "pan"))
    D.knob(x + 8, 31, 4, (pan + 1) / 2, nil, t == mix_sel, true, false)
    local lvl = params:get(tid(t, "level"))
    screen.level(2); screen.rect(x + 6.5, 38.5, 3, 16); screen.stroke()
    screen.level(t == mix_sel and 15 or 9); screen.rect(x + 6, 55 - lvl * 16, 4, lvl * 16); screen.fill()
    if params:get(tid(t, "mute")) == 2 then
      screen.level(15); screen.rect(x + 3, 57, 10, 7); screen.fill(); screen.level(0)
    else
      screen.level(3)
    end
    screen.move(x + 8, 63); screen.text_center("M")
  end
end

function redraw()
  if browsing then return end
  screen.clear()
  screen.line_width(1)
  screen.font_face(1)
  screen.font_size(8)
  local ctx, list = knob_context()

  if lock then
    local t, i = lock.t, lock.i
    local e = eng(t)
    header("LOCK " .. t .. ":" .. e.abbr .. " S" .. i, {}, 0, tracks[t].flash > 0)
    D.vis[e.id](function(k) return (lock_value(t, i, k)) end, {file = tracks[t].file})
    lsel = util.clamp(lsel, 1, #list)
    draw_knobs(list, lsel, function(en) return lock_value(t, i, en.k) end)
  elseif page == 0 then
    if mtab == 1 then
      header("MIX " .. mix_sel .. " " .. S.fmt(S.FX[2], params:get(tid(mix_sel, "pan")))
        .. " " .. S.fmt(S.FX[1], params:get(tid(mix_sel, "level"))), {"MIX", "FX"}, 1)
      draw_mixer()
    else
      header("MASTER", {"MIX", "FX"}, 2)
      local m = {}
      for _, sp in ipairs(S.MASTER) do m[sp.k] = params:get("m_" .. sp.k) end
      m.dbeats = S.DELAY_TIMES[m.dtime][2]
      D.master_vis(m)
      draw_knobs(list, clamp_sel(ctx, list), function(en) return params:get(en.id), false end)
    end
  else
    local t = page
    local e = eng(t)
    header(t .. ":" .. e.name, TABS, cur_tab, tracks[t].flash > 0)
    if cur_tab == 1 then
      draw_seq(t)
    else
      if cur_tab == 2 then
        D.vis[e.id](function(k) return params:get(tid(t, k)) end, {file = tracks[t].file})
      elseif cur_tab == 3 then
        fx_vis(t)
      else
        trk_vis(t)
      end
      draw_knobs(list, clamp_sel(ctx, list), function(en) return params:get(en.id), false end)
    end
  end
  if confirm then
    screen.level(0); screen.rect(10, 18, 108, 30); screen.fill()
    screen.level(15); screen.rect(10.5, 18.5, 107, 29); screen.stroke()
    screen.move(64, 30); screen.text_center(confirm.msg)
    screen.level(6); screen.move(64, 41); screen.text_center("K3 YES   K2 NO")
  end
  screen.update()
end

-- ===================================================================== grid

local function grid_redraw()
  local t = sel
  local tr = tracks[t]
  local len = params:get(tid(t, "len"))
  g:all(0)
  for i = 1, NS do
    local x, y = (i - 1) % 16 + 1, math.floor((i - 1) / 16) + 1
    local st = tr.steps[i]
    local lvl = 0
    if i <= len then lvl = ((i - 1) % 4 == 0) and 3 or 2 end
    if st.on then
      if i <= len then lvl = next(st.locks) and 12 or 9 else lvl = 4 end
    end
    if playing and i == tr.pos then lvl = 15 end
    if held[i] then lvl = 15 end
    g:led(x, y, lvl)
  end
  g:refresh()
end

g.key = function(x, y, z)
  local i = (y - 1) * 16 + x
  local t = sel
  if z == 1 then
    held[i] = {used = false}
    if held[1] and i ~= 1 then
      -- hold step 1 + press: set loop end
      params:set(tid(t, "len"), i)
      held[1].used = true
      held[i].used = true
    elseif not lock then
      lock = {t = t, i = i, src = "grid"}
      cursor = i
    end
  else
    local h = held[i]
    if h and not h.used then
      local st = tracks[t].steps[i]
      st.on = not st.on
    end
    held[i] = nil
    if lock and lock.src == "grid" and lock.i == i then lock = nil end
  end
  grid_dirty = true
end

grid.add = function() grid_dirty = true end

-- ===================================================================== input

local function set_page(p)
  page = util.clamp(p, 0, NT)
  if page > 0 then sel = page end
  if lock and lock.src == "screen" then lock = nil end
end

function enc(n, d)
  if n == 1 then
    set_page(page + d)
    return
  end

  if lock then
    local t, i = lock.t, lock.i
    local list = lock_list(t)
    if n == 2 then
      lsel = util.clamp(lsel + d, 1, #list)
    else
      local en = list[lsel]
      local st = tracks[t].steps[i]
      st.locks[en.k] = S.step(en.sp, (lock_value(t, i, en.k)), d, shift)
      touch("lock:" .. en.k)
      st.on = true
      if lock.src == "grid" and held[i] then held[i].used = true end
    end
    return
  end

  if page == 0 and mtab == 1 then
    if n == 2 then mix_sel = util.clamp(mix_sel + d, 1, NT)
    elseif shift then params:delta(tid(mix_sel, "level"), d)
    else params:delta(tid(mix_sel, "pan"), d) end
    return
  end

  if page > 0 and cur_tab == 1 then
    local t = page
    if n == 2 then
      if shift then params:delta(tid(t, "len"), d)
      else cursor = util.clamp(cursor + d, 1, NS) end
    else
      if shift then
        local st = tracks[t].steps[cursor]
        st.locks.vel = util.clamp((st.locks.vel or 100) + d, 1, 100)
        if st.locks.vel == 100 then st.locks.vel = nil end
      else
        cursor = util.clamp(cursor + d * 16, 1, NS)
      end
    end
    return
  end

  local ctx, list = knob_context()
  local k = clamp_sel(ctx, list)
  if n == 2 then
    ksel[ctx] = util.clamp(k + d, 1, #list)
  else
    local en = list[k]
    if en.sp.t == "ctl" and shift then params:delta(en.id, d / 10) else params:delta(en.id, d) end
    touch(en.id)
  end
end

function key(n, z)
  if n == 1 then shift = z == 1; return end
  if z == 0 then return end

  if confirm then
    if n == 3 then confirm.fn() end
    confirm = nil
    return
  end

  if n == 2 then
    if shift then
      if playing or pending_start then stop() else start() end
    elseif lock then
      lock = nil
    elseif page == 0 then
      mtab = mtab % 2 + 1
    else
      cur_tab = cur_tab % #TABS + 1
    end
    return
  end

  -- K3
  if lock then
    local list = lock_list(lock.t)
    tracks[lock.t].steps[lock.i].locks[list[lsel].k] = nil
    return
  end
  if page == 0 and shift then
    confirm = {msg = "CLEAR ALL 8 TRACKS?", fn = clear_all}
    return
  end
  if page == 0 then
    if mtab == 1 then
      local id = tid(mix_sel, "mute")
      params:set(id, 3 - params:get(id))
    else
      reset_positions(tick_n)
    end
    return
  end
  local t = page
  if cur_tab == 1 then
    if shift then
      lock = {t = t, i = cursor, src = "screen"}
      lsel = 1
    else
      local st = tracks[t].steps[cursor]
      st.on = not st.on
    end
  elseif cur_tab == 2 and eng(t).id == "sample" and not shift then
    browsing = true
    fileselect.enter(_path.audio, function(path)
      browsing = false
      if path and path ~= "cancel" then params:set(tid(t, "file"), path) end
      redraw()
    end)
  elseif cur_tab == 4 and shift then
    confirm = {msg = "CLEAR TRACK " .. t .. "?", fn = function() clear_track(t) end}
  else
    fire(t, nil, true)
  end
  grid_dirty = true
end

-- ===================================================================== lifecycle

local frame_metro

function init()
  for t = 1, NT do
    tracks[t] = {pos = 0, anchor = 0, flash = 0, steps = blank_steps()}
    -- tab is shared by all tracks
  end
  add_params()

  params.action_write = function(_, _, number)
    if number then tab.save(pattern_data(), norns.state.data .. "pattern-" .. number .. ".data") end
  end
  params.action_read = function(_, _, number)
    if number then
      local d = tab.load(norns.state.data .. "pattern-" .. number .. ".data")
      if d then load_pattern(d) end
    end
  end
  params.action_delete = function(_, _, number)
    if number then os.remove(norns.state.data .. "pattern-" .. number .. ".data") end
  end

  util.make_dir(norns.state.data)
  local auto = norns.state.data .. "autosave.pset"
  if util.file_exists(auto) then
    params:read(auto)  -- last session's sounds and mix; the pattern starts empty
  else
    default_kit()
  end
  params:bang()
  ready = true
  for t = 1, NT do update_visibility(t) end

  clock.run(tick_loop)
  frame_metro = metro.init(function()
    for t = 1, NT do
      if tracks[t].flash > 0 then tracks[t].flash = tracks[t].flash - 1 end
    end
    if master_flash > 0 then master_flash = master_flash - 1 end
    redraw()
    if grid_dirty or playing then grid_redraw(); grid_dirty = false end
  end, 1 / 20)
  frame_metro:start()
  start()
end

function cleanup()
  util.make_dir(norns.state.data)
  params:write(norns.state.data .. "autosave.pset")
end
