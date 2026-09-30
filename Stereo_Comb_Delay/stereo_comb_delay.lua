--
--
-- STEREO COMB DELAY
-- Written by Skyler King
--
-- CONTROLS
-- E1  Page
-- E2  Parameter 1
-- E3  Parameter 2
-- K2  Link / Separate
-- K3  L / R
-- K1+K2  Reset R from L
-- K1+E1  Waveform (Mod page)
--
-- PAGES
-- 1  Delay / Spread
-- 2  Feedback / Tone
-- 3  Modulation
-- 4  Mix / Output
--

engine.name = "StereoCombDelay"

local util = require "util"

local SCRIPT_NAME = "STEREO COMB"
local PAGE_COUNT = 4

local page = 1
local edit_side = 1 -- 1 = L, 2 = R
local k1_held = false
local waveform_selecting = false
local waveform_preview = 1
local redraw_metro

local WAVEFORMS = {
  "SINE",
  "SAW",
  "RAMP",
  "SQUARE",
  "RANDOM STEP",
  "RANDOM SMOOTH"
}
local old_monitor_level = nil

local MIN_DELAY_MS = 0.5
local MAX_DELAY_MS = 120.0

local linked_ids = {
  "delay_ms",
  "feedback",
  "mod_depth_ms",
  "mod_rate_hz",
  "tone"
}

local separate_ids = {
  "delay_l_ms", "delay_r_ms",
  "feedback_l", "feedback_r",
  "mod_depth_l_ms", "mod_depth_r_ms",
  "mod_rate_l_hz", "mod_rate_r_hz",
  "tone_l", "tone_r"
}

local function linked()
  return params:get("stereo_mode") == 1
end

local function side_name()
  return edit_side == 1 and "L" or "R"
end

local function get_side_param(base, side)
  local suffix = side == 1 and "l" or "r"

  if base == "mod_depth_ms" then
    return params:get("mod_depth_" .. suffix .. "_ms")
  elseif base == "mod_rate_hz" then
    return params:get("mod_rate_" .. suffix .. "_hz")
  else
    return params:get(base .. "_" .. suffix)
  end
end

local function effective_delay(side)
  local base = params:get(side == 1 and "delay_l_ms" or "delay_r_ms")
  local spread = params:get("spread_ms")

  -- Spread is now a RIGHT-channel-only offset.
  -- Delay L always remains exactly at its set value.
  if side == 1 then
    return util.clamp(base, MIN_DELAY_MS, MAX_DELAY_MS)
  else
    return util.clamp(base + spread, MIN_DELAY_MS, MAX_DELAY_MS)
  end
end

local function send_delay()
  engine.delayL(effective_delay(1) * 0.001)
  engine.delayR(effective_delay(2) * 0.001)
end

local function send_feedback()
  engine.feedbackL(get_side_param("feedback", 1))
  engine.feedbackR(get_side_param("feedback", 2))
end

local function send_mod()
  engine.modDepthL(get_side_param("mod_depth_ms", 1) / 100)
  engine.modDepthR(get_side_param("mod_depth_ms", 2) / 100)
  engine.modRateL(get_side_param("mod_rate_hz", 1))
  engine.modRateR(get_side_param("mod_rate_hz", 2))
end

local function send_waveform()
  -- Lua options are 1..6; SuperCollider Select indexes are 0..5.
  engine.modWave(params:get("mod_waveform") - 1)
end

local function send_tone()
  engine.toneL(get_side_param("tone", 1))
  engine.toneR(get_side_param("tone", 2))
end

local function send_mix()
  engine.mix(params:get("wet_dry"))
  engine.output(params:get("fx_output"))
end

local function send_all()
  send_delay()
  send_feedback()
  send_mod()
  send_waveform()
  send_tone()
  send_mix()
end

local function update_visibility()
  -- LINKED is now a control behavior, not a shared-value parameter bank.
  -- Keep the old shared parameters hidden for preset compatibility and expose
  -- the actual L/R values at all times.
  for _, id in ipairs(linked_ids) do
    params:hide(id)
  end

  for _, id in ipairs(separate_ids) do
    params:show(id)
  end

  if _menu and _menu.rebuild_params then
    _menu.rebuild_params()
  end
end

local function add_params()
  params:add_separator("comb_title", "STEREO COMB DELAY")

  params:add_option("stereo_mode", "parameter mode", {"LINKED", "SEPARATE"}, 1)
  params:set_action("stereo_mode", function()
    -- Switching modes never changes either channel's values.
    -- LINKED simply makes subsequent edits move both sides by the same delta.
    update_visibility()
    send_all()
  end)

  params:add_control(
    "spread_ms", "stereo spread",
    controlspec.new(0, MAX_DELAY_MS, "lin", 0.1, 0.0, "ms")
  )
  params:set_action("spread_ms", send_delay)

  params:add_control(
    "wet_dry", "wet / dry",
    controlspec.new(0, 1, "lin", 0.01, 0.5, "")
  )
  params:set_action("wet_dry", send_mix)

  params:add_control(
    "fx_output", "output level",
    controlspec.new(0, 1.25, "lin", 0.01, 0.85, "")
  )
  params:set_action("fx_output", send_mix)

  params:add_separator("linked_header", "LINKED")

  params:add_control(
    "delay_ms", "delay / comb sweep",
    controlspec.new(MIN_DELAY_MS, MAX_DELAY_MS, "lin", 0.1, 8.0, "ms")
  )
  params:set_action("delay_ms", send_delay)

  params:add_control(
    "feedback", "feedback",
    controlspec.new(-0.97, 0.97, "lin", 0.01, 0.55, "")
  )
  params:set_action("feedback", send_feedback)

  params:add_control(
    "mod_depth_ms", "mod depth",
    controlspec.new(0, 100, "lin", 0.01, 0, "%")
  )
  params:set_action("mod_depth_ms", send_mod)

  params:add_control(
    "mod_rate_hz", "mod rate",
    controlspec.new(0.1, 2000, "lin", 0.1, 0.2, "Hz")
  )
  params:set_action("mod_rate_hz", send_mod)

  params:add_option(
    "mod_waveform", "mod waveform",
    {"Sine", "Saw", "Ramp", "Square", "Random Step", "Random Smooth"}, 1
  )
  params:set_action("mod_waveform", send_waveform)

  params:add_control(
    "tone", "tone",
    controlspec.new(-1, 1, "lin", 0.01, 0, "")
  )
  params:set_action("tone", send_tone)

  params:add_separator("separate_header", "SEPARATE")

  params:add_control(
    "delay_l_ms", "delay L",
    controlspec.new(MIN_DELAY_MS, MAX_DELAY_MS, "lin", 0.1, 8.0, "ms")
  )
  params:set_action("delay_l_ms", send_delay)

  params:add_control(
    "delay_r_ms", "delay R",
    controlspec.new(MIN_DELAY_MS, MAX_DELAY_MS, "lin", 0.1, 8.0, "ms")
  )
  params:set_action("delay_r_ms", send_delay)

  params:add_control(
    "feedback_l", "feedback L",
    controlspec.new(-0.97, 0.97, "lin", 0.01, 0.55, "")
  )
  params:set_action("feedback_l", send_feedback)

  params:add_control(
    "feedback_r", "feedback R",
    controlspec.new(-0.97, 0.97, "lin", 0.01, 0.55, "")
  )
  params:set_action("feedback_r", send_feedback)

  params:add_control(
    "mod_depth_l_ms", "mod depth L",
    controlspec.new(0, 100, "lin", 0.01, 0, "%")
  )
  params:set_action("mod_depth_l_ms", send_mod)

  params:add_control(
    "mod_depth_r_ms", "mod depth R",
    controlspec.new(0, 100, "lin", 0.01, 0, "%")
  )
  params:set_action("mod_depth_r_ms", send_mod)

  params:add_control(
    "mod_rate_l_hz", "mod rate L",
    controlspec.new(0.1, 2000, "lin", 0.1, 0.2, "Hz")
  )
  params:set_action("mod_rate_l_hz", send_mod)

  params:add_control(
    "mod_rate_r_hz", "mod rate R",
    controlspec.new(0.1, 2000, "lin", 0.1, 0.3, "Hz")
  )
  params:set_action("mod_rate_r_hz", send_mod)

  params:add_control(
    "tone_l", "tone L",
    controlspec.new(-1, 1, "lin", 0.01, 0, "")
  )
  params:set_action("tone_l", send_tone)

  params:add_control(
    "tone_r", "tone R",
    controlspec.new(-1, 1, "lin", 0.01, 0, "")
  )
  params:set_action("tone_r", send_tone)
end

local function current_pair()
  if page == 1 then
    return edit_side == 1 and "delay_l_ms" or "delay_r_ms", "spread_ms"

  elseif page == 2 then
    return edit_side == 1 and "feedback_l" or "feedback_r",
           edit_side == 1 and "tone_l" or "tone_r"

  elseif page == 3 then
    return edit_side == 1 and "mod_depth_l_ms" or "mod_depth_r_ms",
           edit_side == 1 and "mod_rate_l_hz" or "mod_rate_r_hz"

  else
    return "wet_dry", "fx_output"
  end
end

local function tone_text(v)
  if math.abs(v) < 0.03 then return "OPEN" end
  if v < 0 then return string.format("LP %.2f", -v) end
  return string.format("HP %.2f", v)
end

local function comb_freq(ms)
  return 1000 / math.max(ms, 0.001)
end

local linked_pairs = {
  delay_l_ms = "delay_r_ms",
  delay_r_ms = "delay_l_ms",
  feedback_l = "feedback_r",
  feedback_r = "feedback_l",
  tone_l = "tone_r",
  tone_r = "tone_l",
  mod_depth_l_ms = "mod_depth_r_ms",
  mod_depth_r_ms = "mod_depth_l_ms",
  mod_rate_l_hz = "mod_rate_r_hz",
  mod_rate_r_hz = "mod_rate_l_hz"
}

local function set_with_link(id, new_value)
  local old_value = params:get(id)
  local delta = new_value - old_value

  params:set(id, new_value)

  if linked() and linked_pairs[id] then
    local other = linked_pairs[id]
    params:set(other, params:get(other) + delta)
  end
end

local function copy_left_to_right()
  -- Capture the ACTUAL audible left delay before removing spread.
  -- This prevents the left channel from jumping when spread was non-zero.
  local left_delay = effective_delay(1)

  -- A non-zero spread would immediately pull the channels apart again,
  -- so a true L -> R reset must also collapse spread to zero.
  -- Reset stereo spread as part of the K1+K2 initialization/reset.
  params:set("spread_ms", 0)

  params:set("delay_l_ms", left_delay)
  params:set("delay_r_ms", left_delay)

  params:set("feedback_r", params:get("feedback_l"))
  params:set("tone_r", params:get("tone_l"))
  params:set("mod_depth_r_ms", params:get("mod_depth_l_ms"))
  params:set("mod_rate_r_hz", params:get("mod_rate_l_hz"))

  -- Explicitly finish the stereo reset with spread at exactly 0.0 ms.
  params:set("spread_ms", 0)

  send_all()
end

local function precise_delta(id, d)
  if id == "delay_l_ms" or id == "delay_r_ms" or id == "spread_ms" then
    if id == "spread_ms" then
      params:set(id, params:get(id) + (d * 0.1))
    else
      set_with_link(id, params:get(id) + (d * 0.1))
    end

  elseif id == "mod_rate_l_hz" or id == "mod_rate_r_hz" then
    set_with_link(id, params:get(id) + (d * 0.1))

  elseif id == "mod_depth_l_ms" or id == "mod_depth_r_ms" then
    set_with_link(id, params:get(id) + (d * 0.1))

  elseif id == "feedback_l" or id == "feedback_r"
      or id == "tone_l" or id == "tone_r" then
    local before = params:get(id)
    params:delta(id, d)
    local after = params:get(id)
    if linked_pairs[id] and linked() then
      params:set(linked_pairs[id], params:get(linked_pairs[id]) + (after - before))
    end

  else
    params:delta(id, d)
  end
end

function enc(n, d)
  if n == 1 then
    if page == 3 and waveform_selecting then
      waveform_preview = util.clamp(waveform_preview + d, 1, #WAVEFORMS)
    else
      -- Outside the modulation waveform picker, E1 changes pages normally.
      page = util.clamp(page + d, 1, PAGE_COUNT)
    end
  elseif n == 2 and not waveform_selecting then
    local a = current_pair()
    precise_delta(a, d)
  elseif n == 3 and not waveform_selecting then
    local _, b = current_pair()
    precise_delta(b, d)
  end
  redraw()
end

function key(n, z)
  if n == 1 then
    if z == 1 then
      k1_held = true

      -- K1 opens the waveform picker only on the modulation page.
      if page == 3 then
        waveform_selecting = true
        waveform_preview = params:get("mod_waveform")
        redraw() -- show waveform list immediately on K1 press
      end
    else
      -- Releasing K1 commits the highlighted waveform and returns to
      -- the normal modulation display.
      if waveform_selecting then
        params:set("mod_waveform", waveform_preview)
        waveform_selecting = false
      end
      k1_held = false
      redraw()
    end
    return
  end

  if z == 0 then return end

  if n == 2 then
    if k1_held then
      copy_left_to_right()
    else
      params:set("stereo_mode", linked() and 2 or 1)
    end
  elseif n == 3 and not linked() and not waveform_selecting then
    edit_side = edit_side == 1 and 2 or 1
  end

  redraw()
end

function redraw()
  screen.clear()
  screen.font_size(8)

  screen.level(15)
  screen.move(3, 12)
  screen.text(SCRIPT_NAME)

  screen.level(7)
  screen.move(125, 12)
  screen.text_right(linked() and "LINK" or ("EDIT " .. side_name()))

  -- While K1 is held on the modulation page, temporarily replace the
  -- normal parameter display with the waveform selection list.
  if page == 3 and waveform_selecting then
    screen.clear()
    screen.font_size(8)

    screen.level(15)
    screen.move(3, 10)
    screen.text("MOD WAVEFORM")

    for i = 1, #WAVEFORMS do
      screen.level(i == waveform_preview and 15 or 5)
      screen.move(5, 12 + (i * 8))
      screen.text((i == waveform_preview and "> " or "  ") .. WAVEFORMS[i])
    end

    screen.update()
    return
  end

  if page == 1 then
    local dl = effective_delay(1)
    local dr = effective_delay(2)

    screen.level(15)
    screen.move(3, 22)
    screen.text("DELAY / SPREAD")

    screen.level(10)
    screen.move(3, 32)
    screen.text(string.format("L %5.1f ms  %7.1f Hz", dl, comb_freq(dl)))
    screen.move(3, 41)
    screen.text(string.format("R %5.1f ms  %7.1f Hz", dr, comb_freq(dr)))
    screen.level(8)
    screen.move(3, 53)
    screen.text(string.format("SPREAD %.1f ms", params:get("spread_ms")))

  elseif page == 2 then
    screen.level(15)
    screen.move(3, 22)
    screen.text("FEEDBACK / TONE")

    screen.level(10)
    screen.move(3, 33)
    screen.text(string.format("L fb %+.2f  %s",
      get_side_param("feedback", 1), tone_text(get_side_param("tone", 1))))
    screen.move(3, 43)
    screen.text(string.format("R fb %+.2f  %s",
      get_side_param("feedback", 2), tone_text(get_side_param("tone", 2))))

  elseif page == 3 then
    screen.level(15)
    screen.move(3, 22)
    screen.text("MODULATION")

    screen.level(10)
    screen.move(3, 33)
    local rl = get_side_param("mod_rate_hz", 1)
    local rr = get_side_param("mod_rate_hz", 2)
    screen.text(string.format("L %5.1f%% @ %7.1fHz",
      get_side_param("mod_depth_ms", 1), rl))
    screen.move(3, 43)
    screen.text(string.format("R %5.1f%% @ %7.1fHz",
      get_side_param("mod_depth_ms", 2), rr))

    screen.level(7)
    screen.move(125, 53)
    screen.text_right(WAVEFORMS[params:get("mod_waveform")])

  else
    screen.level(15)
    screen.move(3, 22)
    screen.text("MIX / OUTPUT")

    screen.level(10)
    screen.move(3, 33)
    screen.text(string.format("wet / dry  %3.0f%%", params:get("wet_dry") * 100))
    screen.move(3, 43)
    screen.text(string.format("output     %.2f", params:get("fx_output")))
  end

  screen.font_size(8)
  screen.level(15)

  -- Dedicated bottom control strip.
  screen.move(2, 63)
  screen.text("K1+K2 RESET")

  screen.move(72, 63)
  screen.text_center("K2 LINK")

  screen.move(126, 63)
  screen.text_right("K3 L/R")

  screen.update()
end

function init()
  -- Preserve the user's direct-monitor setting. We mute the direct hardware
  -- monitor while this script runs because the engine contains its own dry
  -- path for the wet/dry crossfade.
  if params.lookup["monitor_level"] then
    old_monitor_level = params:get("monitor_level")
  end

  add_params()

  if params.lookup["monitor_level"] then
    params:set("monitor_level", -math.huge)
  end

  update_visibility()
  params:bang()

  -- Hard startup reset: ignore any previously saved modulation-depth state.
  params:set("mod_depth_ms", 0)
  params:set("mod_depth_l_ms", 0)
  params:set("mod_depth_r_ms", 0)

  -- Also force the DSP engine itself to zero before sending the remaining state.
  engine.modDepthL(0)
  engine.modDepthR(0)

  send_all()

  redraw_metro = metro.init()
  redraw_metro.time = 1 / 15
  redraw_metro.event = redraw
  redraw_metro:start()

  redraw()
end

function cleanup()
  if redraw_metro then redraw_metro:stop() end

  if old_monitor_level ~= nil and params.lookup["monitor_level"] then
    params:set("monitor_level", old_monitor_level)
  end
end
