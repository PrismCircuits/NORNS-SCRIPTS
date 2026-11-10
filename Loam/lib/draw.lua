-- loam / draw
-- knobs, per-engine step glyphs and per-engine header visuals for the 128x64 screen

local D = {}

local PI = math.pi
local A0, A1 = PI * 0.75, PI * 2.25 -- knob sweep: 7 o'clock to 5 o'clock

local function arc(x, y, r, a, b)
  screen.move(x + r * math.cos(a), y + r * math.sin(a))
  screen.arc(x, y, r, a, b)
  screen.stroke()
end

-- a knob: dim track, bright value arc, pointer, label (or value when selected)
function D.knob(x, y, r, norm, text, sel, bipolar, locked, modded)
  norm = util.clamp(norm, 0, 1)
  local a = A0 + (A1 - A0) * norm
  screen.line_width(1)
  screen.level(sel and 3 or 1)
  arc(x, y, r, A0, A1)
  local s = bipolar and (A0 + A1) / 2 or A0
  local lo, hi = math.min(s, a), math.max(s, a)
  if hi - lo > 0.02 then
    screen.level(sel and 15 or 7)
    arc(x, y, r, lo, hi)
  end
  screen.level(sel and 15 or 5)
  screen.move(x, y)
  screen.line(x + (r - 1) * math.cos(a), y + (r - 1) * math.sin(a))
  screen.stroke()
  if locked then
    screen.level(15)
    screen.rect(x + r - 1, y - r - 1, 3, 3)
    screen.fill()
  end
  if modded then
    -- small ~ : an LFO moves this knob
    screen.level(sel and 15 or 9)
    screen.move(x - r - 3, y - r + 1); screen.line(x - r - 1, y - r - 1); screen.line(x - r + 1, y - r + 1)
    screen.line(x - r + 3, y - r - 1); screen.stroke()
  end
  if text then
    screen.level(sel and 15 or 4)
    screen.move(x, y + r + 9)
    screen.text_center(text)
  end
end

-- ------------------------------------------------------------------ step glyphs
-- each engine draws its steps differently on the SEQ page (cell is 7 x 5)

local G = {}
G.kick = function(x, y) screen.circle(x + 3.5, y + 2.5, 2.5); screen.fill() end
G.snare = function(x, y)
  screen.rect(x, y, 7, 5); screen.fill()
  screen.level(0); screen.rect(x + 2, y + 2, 3, 1); screen.fill()
end
G.clap = function(x, y)
  screen.rect(x, y, 1, 5); screen.rect(x + 3, y, 1, 5); screen.rect(x + 6, y, 1, 5); screen.fill()
end
G.hat = function(x, y) screen.rect(x + 2, y, 3, 5); screen.fill() end
G.tom = function(x, y) screen.circle(x + 3.5, y + 2.5, 2); screen.stroke() end
G.rim = function(x, y) screen.move(x, y + 5); screen.line(x + 7, y); screen.stroke() end
G.bell = function(x, y)
  screen.move(x + 2, y); screen.line(x + 5, y); screen.line(x + 7, y + 5); screen.line(x, y + 5)
  screen.close(); screen.fill()
end
G.synth = function(x, y, note)
  local off = util.clamp(math.floor((96 - (note or 60)) / 18), 0, 4)
  screen.rect(x, y + off, 7, 1.5); screen.fill()
end
G.fm = function(x, y)
  screen.move(x + 3.5, y); screen.line(x + 7, y + 2.5); screen.line(x + 3.5, y + 5); screen.line(x, y + 2.5)
  screen.close(); screen.fill()
end
G.sample = function(x, y)
  screen.move(x, y + 3); screen.line(x + 2, y); screen.line(x + 4, y + 5); screen.line(x + 7, y + 1)
  screen.stroke()
end
D.glyph = G

-- ------------------------------------------------------------------ engine visuals
-- drawn in the band y 10..31 from live parameter values. v(key) returns a value.

local TOP, MID, BOT = 11, 21, 31

local function wave(fn, x0, x1, amp)
  screen.move(x0, MID - fn(0) * amp)
  for x = x0 + 1, x1 do screen.line(x, MID - fn((x - x0) / (x1 - x0)) * amp) end
  screen.stroke()
end

local V = {}

V.kick = function(v)
  local tune, sweep, stime, decay = v("kick_tune"), v("kick_sweep"), v("kick_stime"), v("kick_decay")
  local phase, last = 0, 0
  screen.level(10)
  wave(function(t)
    local sec = t * 0.4
    local f = tune * (1 + sweep * 7 * math.exp(-sec / math.max(stime, 0.001) * 3))
    local dt = sec - last
    last = sec
    phase = phase + f * dt * 0.12
    return math.sin(phase * 2 * PI) * math.exp(-sec / (decay * 0.35))
  end, 0, 127, 9)
  screen.level(15)
  screen.rect(0, MID - 1, 2 + v("kick_click") * 3, 2)
  screen.fill()
end

V.snare = function(v)
  local snappy, sdec, body = v("snare_snappy"), v("snare_sdecay"), v("snare_decay")
  screen.level(6)
  wave(function(t) return math.sin(t * 40) * math.exp(-t * 0.6 / body) * (1 - snappy * 0.4) end, 0, 127, 8)
  screen.level(15)
  for x = 0, 127, 2 do
    local a = math.exp(-(x / 127) * 0.6 / sdec) * snappy * 10
    if a > 0.5 then screen.pixel(x, MID + (math.random() - 0.5) * 2 * a); screen.fill() end
  end
end

V.clap = function(v)
  local sp, dec = v("clap_spread"), v("clap_decay")
  local px = sp / 0.4 * 128
  screen.level(15)
  for i = 0, 2 do
    local x = 4 + i * px
    screen.move(x, BOT); screen.line(x, TOP); screen.stroke()
  end
  local x0 = 4 + 3 * px
  for x = x0, 127 do
    local a = math.exp(-((x - x0) / 127) * 0.4 / dec) * 9
    if a > 0.4 and math.random() < 0.6 then
      screen.level(math.random() < 0.5 and 8 or 4)
      screen.move(x, MID - a * math.random()); screen.line(x, MID + a * math.random()); screen.stroke()
    end
  end
end

V.hat = function(v)
  local ratios = {2, 3, 4.16, 5.43, 6.79, 8.21}
  local tune, decay, color = v("hat_tune"), v("hat_decay"), v("hat_color")
  for i, r in ipairs(ratios) do
    local x = util.linlin(2 * 25, 8.21 * 90, 4, 70, r * tune)
    local h = 6 + (i % 3) * 4
    screen.level(i % 2 == 0 and 15 or 9)
    screen.rect(x, BOT - h, 2, h); screen.fill()
  end
  -- color marker + decay bar
  local cx = util.linlin(4000, 15000, 4, 70, color)
  screen.level(3); screen.move(cx, TOP); screen.line(cx, BOT); screen.stroke()
  local w = util.linlin(math.log(0.01), math.log(1.5), 4, 50, math.log(decay))
  screen.level(12); screen.rect(76, MID - 1, w, 3); screen.fill()
  screen.level(4); screen.rect(76, MID - 4, 50, 9); screen.stroke()
end

V.tom = function(v)
  local tune, sweep, decay = v("tom_tune"), v("tom_sweep"), v("tom_decay")
  local r = util.linlin(50, 400, 10, 4, tune)
  screen.level(12); screen.circle(14, MID, r); screen.stroke()
  screen.level(4); screen.circle(14, MID, r + 2); screen.stroke()
  local phase, last = 0, 0
  screen.level(9)
  wave(function(t)
    local sec = t * 0.6
    local f = tune * (1 + sweep * math.exp(-sec / (decay * 0.6) * 3))
    phase = phase + f * (sec - last) * 0.1
    last = sec
    return math.sin(phase * 2 * PI) * math.exp(-sec / (decay * 0.5))
  end, 32, 127, 9)
end

V.rim = function(v)
  local tune, decay, body = v("rim_tune"), v("rim_decay"), v("rim_body")
  screen.level(12)
  screen.move(4, BOT); screen.line(30, TOP); screen.stroke()
  screen.level(4); screen.rect(2, BOT - 2, 30, 2); screen.fill()
  local len = util.linlin(math.log(0.005), math.log(0.15), 10, 90, math.log(decay))
  screen.level(15)
  wave(function(t)
    if t * 90 > len then return 0 end
    return ((t * tune / 25) % 1 < 0.5 and 1 or -1) * (1 - t * 90 / len) * (0.4 + body * 0.6)
  end, 36, 127, 9)
end

V.bell = function(v)
  local tune, ratio, decay = v("bell_tune"), v("bell_ratio"), v("bell_decay")
  screen.level(12)
  screen.move(8, TOP); screen.line(20, TOP); screen.line(26, BOT); screen.line(2, BOT); screen.close(); screen.stroke()
  screen.level(6); screen.rect(12, TOP - 1, 4, 2); screen.fill()
  local d = util.linlin(math.log(0.05), math.log(1.5), 0.2, 1, math.log(decay))
  screen.level(10)
  wave(function(t) return ((t * tune / 30) % 1 < 0.5 and 0.5 or -0.5) * math.exp(-t / d) end, 34, 127, 8)
  screen.level(5)
  wave(function(t) return ((t * tune * ratio / 30) % 1 < 0.5 and 0.5 or -0.5) * math.exp(-t / d) end, 34, 127, 6)
end

local function wavefn(w)
  if w == 1 then return function(p) return math.sin(p * 2 * PI) end
  elseif w == 2 then return function(p) return 1 - 4 * math.abs((p % 1) - 0.5) end
  elseif w == 3 then return function(p) return 2 * (p % 1) - 1 end
  elseif w == 4 then return function(p) return (p % 1) < 0.5 and 1 or -1 end
  else return function() return math.random() * 2 - 1 end end
end

V.synth = function(v)
  -- adsr on the left
  local a, d, s, r = v("synth_atk"), v("synth_dec"), v("synth_sus"), v("synth_rel")
  local scale = 40 / (a + d + r + 0.5)
  local x1 = a * scale
  local x2 = x1 + d * scale
  local x3 = x2 + 0.5 * scale
  local x4 = x3 + r * scale
  local h = BOT - TOP
  screen.level(12)
  screen.move(0, BOT); screen.line(x1, TOP); screen.line(x2, BOT - s * h); screen.line(x3, BOT - s * h); screen.line(x4, BOT)
  screen.stroke()
  -- oscillator in the middle
  local fn = wavefn(v("synth_wave"))
  screen.level(9)
  wave(function(t) return fn(t * 2) end, 48, 80, 6)
  -- filter response on the right
  local ft = v("synth_ftype")
  local cut = util.linlin(math.log(30), math.log(16000), 0, 1, math.log(v("synth_cutoff")))
  local res = v("synth_res")
  screen.level(15)
  screen.move(86, BOT)
  for x = 86, 127 do
    local p = (x - 86) / 41
    local dist = (p - cut) * 6
    local y
    if ft == 1 then y = p < cut and 1 or math.max(0, 1 - dist)
    elseif ft == 2 then y = p > cut and 1 or math.max(0, 1 + dist)
    elseif ft == 3 then y = math.max(0, 1 - math.abs(dist))
    else y = math.min(1, math.abs(dist)) end
    y = y + res * math.max(0, 1 - math.abs(dist) * 2) * 0.8
    screen.line(x, BOT - util.clamp(y, 0, 1.3) * (h * 0.75))
  end
  screen.stroke()
  if v("synth_ldepth") > 0.01 then
    screen.level(4); screen.move(84, TOP + 3); screen.text_right("~")
  end
end

V.fm = function(v)
  local ratio, index = v("fm_ratio"), v("fm_index")
  screen.level(12)
  screen.rect(2, TOP + 1, 10, 8); screen.stroke()
  screen.rect(2, BOT - 8, 10, 8); screen.stroke()
  screen.move(5, TOP + 7); screen.text("M")
  screen.move(5, BOT - 2); screen.text("C")
  screen.move(7, TOP + 10); screen.line(7, BOT - 9); screen.stroke()
  if v("fm_fb") > 0.01 then
    screen.level(6); screen.move(12, TOP + 3); screen.line(15, TOP + 3); screen.line(15, TOP + 7); screen.line(12, TOP + 7); screen.stroke()
  end
  screen.level(15)
  wave(function(t)
    return math.sin(t * 6 * PI + index * 0.6 * math.sin(t * 6 * PI * ratio) * (1 - t * v("fm_ienv")))
  end, 22, 127, 9)
end

V.sample = function(v, info)
  local name = info.file
  local s0, s1 = v("smp_start"), v("smp_end")
  if name == nil or name == "" then
    screen.level(4)
    screen.rect(0, TOP, 127, BOT - TOP); screen.stroke()
    screen.level(10)
    screen.move(64, MID + 2); screen.text_center("K3: LOAD SAMPLE")
    return
  end
  -- stable pseudo-waveform from the file name
  local seed = 7
  for i = 1, #name do seed = (seed * 31 + name:byte(i)) % 65521 end
  for x = 0, 127 do
    seed = (seed * 1103 + 12345) % 65521
    local env = math.exp(-x / 60) * 0.8 + 0.2
    local a = (seed / 65521) * 9 * env
    local inside = x / 127 >= math.min(s0, s1) and x / 127 <= math.max(s0, s1)
    screen.level(inside and 10 or 2)
    screen.move(x, MID - a); screen.line(x, MID + a); screen.stroke()
  end
  screen.level(15)
  local xa, xb = s0 * 127, s1 * 127
  screen.move(xa, TOP); screen.line(xa, BOT); screen.stroke()
  screen.move(xb, TOP); screen.line(xb, BOT); screen.stroke()
  if v("smp_rev") == 2 then
    screen.move(xb - 2, TOP + 2); screen.line(xb - 8, TOP + 2); screen.stroke()
  end
  screen.level(0); screen.rect(0, TOP - 1, math.min(127, screen.text_extents(name) + 3), 7); screen.fill()
  screen.level(8); screen.move(1, TOP + 5); screen.text(name)
end

D.vis = V

-- master bus picture: compressor curve, delay taps, reverb tail
function D.master_vis(m)
  -- compressor transfer curve (input dB -> output dB), 22 x 20 box
  local bx, by, bw, bh = 0, TOP, 22, 20
  screen.level(3); screen.rect(bx, by, bw, bh); screen.stroke()
  screen.level(15)
  local th, ra = m.cthresh, m.cratio
  for i = 0, bw do
    local inp = -48 + i / bw * 48
    local out = inp > th and th + (inp - th) / ra or inp
    local y = by + bh - ((out + 48) / 48) * bh
    if i == 0 then screen.move(bx + i, y) else screen.line(bx + i, y) end
  end
  screen.stroke()
  -- delay taps
  local sp = util.linlin(0.25, 4, 4, 22, m.dbeats)
  local x, a = 30, 1
  while x < 84 and a > 0.05 do
    screen.level(math.max(1, math.floor(a * 15)))
    screen.move(x, BOT); screen.line(x, BOT - a * 18 * m.dlvl - 1); screen.stroke()
    x = x + sp
    a = a * m.dfb
  end
  -- reverb tail
  for xx = 90, 127 do
    local amp = math.exp(-(xx - 90) / (4 + m.rsize * 30)) * 9 * m.rlvl
    screen.level(math.random() < 0.5 and 6 or 2)
    screen.move(xx, MID - amp * math.random()); screen.line(xx, MID + amp * math.random()); screen.stroke()
  end
end

return D
