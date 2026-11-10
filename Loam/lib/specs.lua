-- loam / specs
-- every engine, its parameters, and how values are shown and sent

local ControlSpec = require 'controlspec'
local musicutil = require 'musicutil'

local S = {}

local function C(k, n, min, max, warp, def, u, bi)
  return {k = k, n = n, t = "ctl", cs = ControlSpec.new(min, max, warp, 0, def, ""), u = u, bi = bi, def = def}
end
local function I(k, n, min, max, def, u)
  return {k = k, n = n, t = "int", min = min, max = max, def = def, u = u}
end
local function O(k, n, opts, def)
  return {k = k, n = n, t = "opt", opts = opts, def = def}
end

local FTYPES = {"LP", "HP", "BP", "NOTCH"}

-- sound engines. `def` is the SynthDef name in Engine_Loam.sc
S.ENGINES = {
  {id = "kick", name = "KICK", abbr = "KCK", def = "loam_kick",
    desc = "sine + pitch sweep + click", params = {
    C("kick_tune", "TUNE", 25, 120, "exp", 48, "hz"),
    C("kick_sweep", "SWEEP", 0, 1, "lin", 0.5, "%"),
    C("kick_stime", "S.TIME", 0.005, 0.3, "exp", 0.05, "s"),
    C("kick_decay", "DECAY", 0.05, 2, "exp", 0.5, "s"),
    C("kick_click", "CLICK", 0, 1, "lin", 0.3, "%"),
    C("kick_drive", "DRIVE", 0, 1, "lin", 0.2, "%"),
  }},
  {id = "snare", name = "SNARE", abbr = "SNR", def = "loam_snare",
    desc = "2 triangles + noise wires", params = {
    C("snare_tune", "TUNE", 100, 400, "exp", 185, "hz"),
    C("snare_decay", "BODY", 0.03, 0.6, "exp", 0.15, "s"),
    C("snare_snappy", "SNAPPY", 0, 1, "lin", 0.7, "%"),
    C("snare_sdecay", "WIRES", 0.03, 0.8, "exp", 0.22, "s"),
    C("snare_color", "COLOR", 500, 9000, "exp", 2500, "hz"),
  }},
  {id = "clap", name = "CLAP", abbr = "CLP", def = "loam_clap",
    desc = "band-passed noise x3 + tail", params = {
    C("clap_tone", "TONE", 500, 4000, "exp", 1200, "hz"),
    C("clap_spread", "SPREAD", 0.004, 0.03, "exp", 0.011, "s"),
    C("clap_decay", "DECAY", 0.05, 1, "exp", 0.25, "s"),
  }},
  {id = "hat", name = "HAT", abbr = "HAT", def = "loam_hat",
    desc = "6 square oscs, metallic ratios", params = {
    C("hat_tune", "TUNE", 25, 90, "exp", 40, "hz"),
    C("hat_color", "COLOR", 4000, 15000, "exp", 10000, "hz"),
    C("hat_decay", "DECAY", 0.01, 1.5, "exp", 0.06, "s"),
    C("hat_noise", "NOISE", 0, 1, "lin", 0.2, "%"),
  }},
  {id = "tom", name = "TOM", abbr = "TOM", def = "loam_tom",
    desc = "swept sine + skin noise", params = {
    C("tom_tune", "TUNE", 50, 400, "exp", 110, "hz"),
    C("tom_sweep", "SWEEP", 0, 2, "lin", 0.5, "%"),
    C("tom_decay", "DECAY", 0.05, 1.5, "exp", 0.45, "s"),
    C("tom_noise", "SKIN", 0, 1, "lin", 0.15, "%"),
  }},
  {id = "rim", name = "RIM", abbr = "RIM", def = "loam_rim",
    desc = "triangle + pulse click", params = {
    C("rim_tune", "TUNE", 600, 3500, "exp", 1700, "hz"),
    C("rim_decay", "DECAY", 0.005, 0.15, "exp", 0.035, "s"),
    C("rim_body", "BODY", 0, 1, "lin", 0.5, "%"),
  }},
  {id = "bell", name = "COWBELL", abbr = "BEL", def = "loam_bell",
    desc = "2 squares through a band-pass", params = {
    C("bell_tune", "TUNE", 300, 900, "exp", 540, "hz"),
    C("bell_ratio", "RATIO", 1, 2.5, "lin", 1.48, "x"),
    C("bell_tone", "TONE", 800, 6000, "exp", 2640, "hz"),
    C("bell_decay", "DECAY", 0.05, 1.5, "exp", 0.35, "s"),
  }},
  {id = "synth", name = "SYNTH", abbr = "SYN", def = "loam_synth",
    desc = "2 osc + sub, filter, adsr, lfo", params = {
    I("synth_note", "NOTE", 24, 96, 36, "note"),
    O("synth_wave", "WAVE", {"SIN", "TRI", "SAW", "SQR", "NSE"}, 3),
    C("synth_pw", "PW", 0.05, 0.95, "lin", 0.5, "%"),
    C("synth_det", "DETUNE", 0, 50, "lin", 7, "ct"),
    C("synth_osc2", "OSC2", 0, 1, "lin", 0.5, "%"),
    C("synth_sub", "SUB", 0, 1, "lin", 0.3, "%"),
    O("synth_ftype", "FILTER", FTYPES, 1),
    C("synth_cutoff", "CUTOFF", 30, 16000, "exp", 800, "hz"),
    C("synth_res", "RES", 0, 1, "lin", 0.3, "%"),
    C("synth_fenv", "F.ENV", 0, 1, "lin", 0.5, "%"),
    C("synth_fdec", "F.DEC", 0.01, 2, "exp", 0.25, "s"),
    C("synth_atk", "ATTACK", 0.001, 2, "exp", 0.003, "s"),
    C("synth_dec", "DECAY", 0.01, 2, "exp", 0.2, "s"),
    C("synth_sus", "SUSTAIN", 0, 1, "lin", 0.5, "%"),
    C("synth_rel", "RELEASE", 0.005, 10, "exp", 0.2, "s"),
    C("synth_lrate", "LFO HZ", 0.05, 30, "exp", 3, "hz"),
    C("synth_ldepth", "LFO AMT", 0, 1, "lin", 0, "%"),
    O("synth_lshape", "LFO WAV", {"SIN", "TRI", "SAW", "SQR", "S&H"}, 1),
    O("synth_ldest", "LFO DST", {"PITCH", "CUTOFF", "AMP", "PAN"}, 2),
  }},
  {id = "fm", name = "FM", abbr = "FM", def = "loam_fm",
    desc = "2-op fm, feedback modulator", params = {
    I("fm_note", "NOTE", 24, 96, 60, "note"),
    C("fm_ratio", "RATIO", 0.25, 8, "lin", 2, "x"),
    C("fm_index", "INDEX", 0, 10, "lin", 2, "x"),
    C("fm_ienv", "I.ENV", 0, 1, "lin", 0.5, "%"),
    C("fm_fb", "FEEDBK", 0, 1.5, "lin", 0, "x"),
    C("fm_atk", "ATTACK", 0.001, 1, "exp", 0.002, "s"),
    C("fm_decay", "DECAY", 0.02, 3, "exp", 0.6, "s"),
  }},
  {id = "sample", name = "SAMPLE", abbr = "SMP", def = "loam_sample",
    desc = "buffer player, filter, env", params = {
    I("smp_pitch", "PITCH", -24, 24, 0, "st"),
    C("smp_start", "START", 0, 1, "lin", 0, "%"),
    C("smp_end", "END", 0, 1, "lin", 1, "%"),
    O("smp_rev", "DIR", {"FWD", "REV"}, 1),
    O("smp_mode", "MODE", {"ONESHOT", "GATE"}, 1),
    C("smp_atk", "ATTACK", 0.001, 1, "exp", 0.002, "s"),
    C("smp_rel", "RELEASE", 0.005, 10, "exp", 0.05, "s"),
    O("smp_ftype", "FILTER", FTYPES, 1),
    C("smp_cutoff", "CUTOFF", 30, 18000, "exp", 18000, "hz"),
    C("smp_res", "RES", 0, 1, "lin", 0.1, "%"),
    O("smp_norm", "NORMALIZE", {"OFF", "ON"}, 2),
  }},
}

S.ENGINE_NAMES = {}
S.ENGINE_INDEX = {}
for i, e in ipairs(S.ENGINES) do
  S.ENGINE_NAMES[i] = e.name
  S.ENGINE_INDEX[e.id] = i
end

-- clock rates. ticks are 1/96 of a beat, so x1 = one 16th note = 24 ticks
S.RATES = {
  {"1/8", 192}, {"1/6", 144}, {"1/4", 96}, {"1/3", 72}, {"1/2", 48}, {"2/3", 36},
  {"3/4", 32}, {"x1", 24}, {"4/3", 18}, {"3/2", 16}, {"x2", 12}, {"x3", 8},
  {"x4", 6}, {"x6", 4}, {"x8", 3},
}
S.RATE_NAMES = {}
for i, r in ipairs(S.RATES) do S.RATE_NAMES[i] = r[1] end
S.RATE_DEFAULT = 8

S.CHOKES = {"OFF", "MONO", "A", "B", "C", "D"}

-- per-track mixer / insert effects (sent to the track's fx synth)
S.FX = {
  C("level", "LEVEL", 0, 1, "lin", 0.8, "%"),
  C("pan", "PAN", -1, 1, "lin", 0, "pan", true),
  C("filter", "FILTER", -1, 1, "lin", 0, "filt", true),
  C("drive", "DRIVE", 0, 1, "lin", 0, "%"),
  I("bits", "BITS", 2, 16, 16, "bit"),
  C("srate", "S.RATE", 400, 48000, "exp", 48000, "hz"),
  C("dly", "DELAY", 0, 1, "lin", 0, "%"),
  C("rev", "REVERB", 0, 1, "lin", 0, "%"),
}

-- per-track sequencer settings (handled in lua)
S.TRK = {
  O("engine", "ENGINE", S.ENGINE_NAMES, 1),
  I("len", "LENGTH", 1, 128, 16, "step"),
  O("rate", "RATE", S.RATE_NAMES, S.RATE_DEFAULT),
  I("prob", "PROB", 0, 100, 100, "pct"),
  O("choke", "CHOKE", S.CHOKES, 1),
  C("gate", "GATE", 0.1, 8, "exp", 1, "stp"),
  O("mute", "MUTE", {"OFF", "ON"}, 1),
}

S.DELAY_TIMES = {
  {"1/16", 0.25}, {"1/8", 0.5}, {"3/16", 0.75}, {"1/4", 1}, {"3/8", 1.5}, {"1/2", 2}, {"3/4", 3}, {"1", 4},
}
local dnames = {}
for i, d in ipairs(S.DELAY_TIMES) do dnames[i] = d[1] end

-- master bus
S.MASTER = {
  O("dtime", "DLY TIME", dnames, 5),
  C("dfb", "DLY FB", 0, 0.95, "lin", 0.45, "%"),
  C("dtone", "DLY TONE", 500, 12000, "exp", 4000, "hz"),
  C("dlvl", "DLY LVL", 0, 1, "lin", 0.7, "%"),
  C("rsize", "REV SIZE", 0, 1, "lin", 0.8, "%"),
  C("rdamp", "REV DAMP", 0, 1, "lin", 0.5, "%"),
  C("rlvl", "REV LVL", 0, 1, "lin", 0.7, "%"),
  C("mfilter", "FILTER", -1, 1, "lin", 0, "filt", true),
  C("cthresh", "THRESH", -40, 0, "lin", -12, "db"),
  C("cratio", "RATIO", 1, 20, "exp", 4, "rat"),
  C("catk", "ATTACK", 0.001, 0.2, "exp", 0.01, "s"),
  C("crel", "RELEASE", 0.02, 1, "exp", 0.15, "s"),
  C("cgain", "MAKEUP", 0, 18, "lin", 3, "db"),
  C("vol", "VOLUME", 0, 1, "lin", 0.8, "%"),
  I("mlen", "M.LENGTH", 0, 512, 0, "mlen"),
}

-- pseudo parameters that only exist as per-step locks
S.STEP = {
  I("vel", "VELO", 1, 100, 100, "pct"),
  I("prob", "PROB", 0, 100, 100, "pct"),
}

S.TEMPO = I("clock_tempo", "TEMPO", 20, 300, 120, "bpm")

-- lookup of every lockable engine key -> spec
S.BY_KEY = {}
for _, e in ipairs(S.ENGINES) do
  for _, p in ipairs(e.params) do S.BY_KEY[p.k] = p end
end

function S.norm(spec, v)
  if spec.t == "ctl" then return spec.cs:unmap(v)
  elseif spec.t == "int" then return (v - spec.min) / math.max(1, spec.max - spec.min)
  else return (v - 1) / math.max(1, #spec.opts - 1) end
end

function S.to_sc(spec, v)
  if spec.t == "opt" then return v - 1 end
  return v
end

-- step a value by d encoder detents (used for per-step locks)
function S.step(spec, v, d, fine)
  if spec.t == "ctl" then
    local raw = util.clamp(spec.cs:unmap(v) + d * (fine and 0.001 or 0.01), 0, 1)
    return spec.cs:map(raw)
  elseif spec.t == "int" then
    return util.clamp(math.floor(v + d + 0.5), spec.min, spec.max)
  else
    return util.clamp(v + d, 1, #spec.opts)
  end
end

function S.fmt(spec, v)
  local u = spec.u
  if spec.t == "opt" then return spec.opts[v] or "?" end
  if u == "hz" then
    if v >= 1000 then return string.format("%.1fk", v / 1000) end
    return string.format("%d", math.floor(v + 0.5))
  elseif u == "s" then
    if v < 1 then return string.format("%dms", math.floor(v * 1000 + 0.5)) end
    return string.format("%.2fs", v)
  elseif u == "%" then return string.format("%d%%", math.floor(v * 100 + 0.5))
  elseif u == "pct" then return string.format("%d%%", v)
  elseif u == "note" then return musicutil.note_num_to_name(v, true)
  elseif u == "st" then return string.format("%+dst", v)
  elseif u == "ct" then return string.format("%dct", math.floor(v + 0.5))
  elseif u == "x" then return string.format("%.2fx", v)
  elseif u == "db" then return string.format("%.1fdB", v)
  elseif u == "rat" then return string.format("%.1f:1", v)
  elseif u == "bit" then return string.format("%dbit", v)
  elseif u == "stp" then return string.format("%.2f st", v)
  elseif u == "step" then return string.format("%d", v)
  elseif u == "bpm" then return string.format("%d bpm", math.floor(v + 0.5))
  elseif u == "mlen" then return v == 0 and "OFF" or string.format("%d", v)
  elseif u == "pan" then
    if math.abs(v) < 0.02 then return "C" end
    return (v < 0 and "L" or "R") .. math.floor(math.abs(v) * 100 + 0.5)
  elseif u == "filt" then
    if math.abs(v) < 0.02 then return "OPEN" end
    return (v < 0 and "LP " or "HP ") .. math.floor(math.abs(v) * 100 + 0.5)
  end
  return string.format("%.2f", v)
end

return S
