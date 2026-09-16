--[[
  zhimi.fan.za5 — Mi Smart Standing Fan 2 (DC inverter), v2 mapping.

  Standard caps:
    switch                       <- siid=2 piid=1 (power, bool)
    fanSpeedPercent (0..100)     <- siid=6 piid=8 (exact speed; 0 = power off)
    fanOscillationMode {fixed,horizontal} <- siid=2 piid=3 (horizontal swing bool)
    mode {Natural,Straight}      <- siid=2 piid=7 (0=Natural Wind, 1=Straight Wind)
    indicatorLightMode          <- siid=4 piid=3 (brightness mapped to off/dim/bright)
    relativeHumidityMeasurement  <- siid=7 piid=1
    temperatureMeasurement       <- siid=7 piid=7
  Custom caps (namespace: earthpanel38939):
    childLock {locked,unlocked}  <- siid=3 piid=1 (lock bool)
    alarmBuzzer {on,off}         <- siid=5 piid=1
    fanOscillationAngle (30..120°) <- siid=2 piid=5
    powerOffTimer (0..600 min)   <- siid=2 piid=10 (device stores seconds)
]]

local capabilities = require "st.capabilities"
local events = require "devices.events"

local M = {}
local NS = "earthpanel38939"
local cap_childLock       = capabilities[NS .. ".childLock"]
local cap_alarmBuzzer     = capabilities[NS .. ".alarmBuzzer"]
local cap_oscillationAngle = capabilities[NS .. ".fanOscillationDegrees"]
local cap_oscillationControl = capabilities[NS .. ".fanOscillationControl"]
local cap_powerOffTimer   = capabilities[NS .. ".powerOffTimer"]
local cap_indicatorMode   = capabilities[NS .. ".indicatorLightMode"]

local SIID_FAN = 2
local PIID_POWER = 1
local PIID_SWING = 3
local PIID_ANGLE = 5
local PIID_FAN_MODE = 7
local PIID_POWER_OFF_DELAY = 10

local SIID_LOCK = 3
local PIID_LOCK = 1
local SIID_INDICATOR = 4
local PIID_INDICATOR_BRIGHT = 3
local SIID_ALARM = 5
local PIID_ALARM = 1
local SIID_CUSTOM = 6
local PIID_SPEED_PERCENT = 8
local SIID_ENV = 7
local PIID_HUM = 1
local PIID_TEMP = 7

local MODE_LABELS = { [0] = "자연풍", [1] = "직선풍" }
local LABEL_TO_MODE_CODE = { ["자연풍"] = 0, ["직선풍"] = 1 }

M.supported_modes = { "자연풍", "직선풍" }
M.is_fan = true

M.refresh_props = {
  { siid = SIID_FAN,        piid = PIID_POWER,           did = "power" },
  { siid = SIID_CUSTOM,     piid = PIID_SPEED_PERCENT,   did = "speed-percent" },
  { siid = SIID_FAN,        piid = PIID_SWING,           did = "swing" },
  { siid = SIID_FAN,        piid = PIID_ANGLE,           did = "angle" },
  { siid = SIID_FAN,        piid = PIID_FAN_MODE,        did = "fan-mode" },
  { siid = SIID_FAN,        piid = PIID_POWER_OFF_DELAY, did = "power-off-delay" },
  { siid = SIID_LOCK,       piid = PIID_LOCK,            did = "lock" },
  { siid = SIID_INDICATOR,  piid = PIID_INDICATOR_BRIGHT,did = "indicator" },
  { siid = SIID_ALARM,      piid = PIID_ALARM,           did = "alarm" },
  { siid = SIID_ENV,        piid = PIID_HUM,             did = "humidity" },
  { siid = SIID_ENV,        piid = PIID_TEMP,            did = "temperature" },
}

local function select_props(wanted)
  local selected = {}
  for _, prop in ipairs(M.refresh_props) do
    if wanted[prop.did] then selected[#selected + 1] = prop end
  end
  return selected
end

M.core_props = select_props{
  power = true, ["speed-percent"] = true, swing = true,
  ["fan-mode"] = true, ["power-off-delay"] = true,
}
M.aux_props = select_props{
  angle = true, lock = true, indicator = true, alarm = true,
  humidity = true, temperature = true,
}

local function confirmed(expected, ok, err)
  if not ok then return nil, err, expected end
  return true, nil, expected
end

local SUPPORTED_OSCILLATION = { "fixed", "horizontal" }
local INDICATOR_LEVEL_TO_MODE = { [0] = "off", [50] = "dim", [100] = "bright" }
local INDICATOR_MODE_TO_LEVEL = { off = 0, dim = 50, bright = 100 }

local function indicator_mode(level)
  if INDICATOR_LEVEL_TO_MODE[level] then return INDICATOR_LEVEL_TO_MODE[level] end
  if level <= 0 then return "off" end
  if level < 75 then return "dim" end
  return "bright"
end

local function emit_supported(device)
  events.emit(device, capabilities.mode,
    capabilities.mode.supportedModes(M.supported_modes, { visibility = { displayed = false } }))
  events.emit(device, capabilities.fanOscillationMode,
    capabilities.fanOscillationMode.supportedFanOscillationModes(SUPPORTED_OSCILLATION, { visibility = { displayed = false } }))
  events.emit(device, capabilities.fanOscillationMode,
    capabilities.fanOscillationMode.availableFanOscillationModes(SUPPORTED_OSCILLATION, { visibility = { displayed = false } }))
end

function M.on_added(device) emit_supported(device) end
function M.on_init(device)  emit_supported(device) end

function M.apply_state(device, p)
  local power = p["power"]
  if power ~= nil then
    events.emit(device, capabilities.switch,
      power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end

  local speed_percent = p["speed-percent"]
  if speed_percent ~= nil then
    local effective = (power == false) and 0 or speed_percent
    events.emit(device, capabilities.fanSpeedPercent, capabilities.fanSpeedPercent.percent(effective))
  end

  local swing = p["swing"]
  if swing ~= nil then
    events.emit(device, capabilities.fanOscillationMode,
      capabilities.fanOscillationMode.fanOscillationMode(swing and "horizontal" or "fixed"))
    if cap_oscillationControl then
      events.emit(device, cap_oscillationControl,
        cap_oscillationControl.fanOscillationMode(swing and "horizontal" or "fixed"))
    end
  end

  local angle = p["angle"]
  if angle ~= nil and cap_oscillationAngle then
    events.emit(device, cap_oscillationAngle, cap_oscillationAngle.degrees(angle))
  end

  local fan_mode = p["fan-mode"]
  if fan_mode ~= nil and MODE_LABELS[fan_mode] then
    events.emit(device, capabilities.mode, capabilities.mode.mode(MODE_LABELS[fan_mode]))
  end

  local lock = p["lock"]
  if lock ~= nil and cap_childLock then
    events.emit(device, cap_childLock, cap_childLock.lock(lock and "locked" or "unlocked"))
  end

  local delay = p["power-off-delay"]
  if delay ~= nil and cap_powerOffTimer then
    events.emit(device, cap_powerOffTimer,
      cap_powerOffTimer.minutes({ value = math.floor(delay / 60), unit = "min" }))
  end

  local alarm = p["alarm"]
  if alarm ~= nil and cap_alarmBuzzer then
    events.emit(device, cap_alarmBuzzer, cap_alarmBuzzer.buzzer(alarm and "on" or "off"))
  end

  local indicator = p["indicator"]
  if indicator ~= nil then
    events.emit(device, cap_indicatorMode,
      cap_indicatorMode.indicator(indicator_mode(indicator)))
    -- Backward compatibility while a hub is still applying the new profile.
    events.emit(device, capabilities.switchLevel, capabilities.switchLevel.level(indicator))
  end

  local hum = p["humidity"]
  if hum ~= nil then
    events.emit(device, capabilities.relativeHumidityMeasurement,
      capabilities.relativeHumidityMeasurement.humidity(hum))
  end

  local temp = p["temperature"]
  if temp ~= nil then
    events.emit(device, capabilities.temperatureMeasurement,
      capabilities.temperatureMeasurement.temperature({ value = temp, unit = "C" }))
  end
end

-- Setters
function M.set_switch(client, on)
  local value = on and true or false
  return confirmed({ power = value },
    client:set_property(SIID_FAN, PIID_POWER, value, "power"))
end

function M.set_fan_speed(client, speed)
  return M.set_fan_speed_percent(client, speed)
end

function M.set_fan_speed_percent(client, pct)
  pct = math.floor(tonumber(pct) or 0)
  if pct <= 0 then
    return confirmed({ power = false },
      client:set_property(SIID_FAN, PIID_POWER, false, "power"))
  end
  pct = math.max(1, math.min(100, pct))
  local ok, e = client:set_property(SIID_FAN, PIID_POWER, true, "power")
  local expected = { power = true, ["speed-percent"] = pct }
  if not ok then return nil, e, expected end
  return confirmed(expected,
    client:set_property(SIID_CUSTOM, PIID_SPEED_PERCENT, pct, "speed-percent"))
end

function M.set_switch_level(client, level)
  level = math.max(0, math.min(100, level))
  return confirmed({ indicator = level },
    client:set_property(SIID_INDICATOR, PIID_INDICATOR_BRIGHT, level, "indicator"))
end

function M.set_indicator(client, mode)
  local level = INDICATOR_MODE_TO_LEVEL[mode]
  if level == nil then return nil, "unknown indicator mode: " .. tostring(mode) end
  return confirmed({ indicator = level },
    client:set_property(SIID_INDICATOR, PIID_INDICATOR_BRIGHT, level, "indicator"))
end

function M.set_oscillation_mode(client, mode)
  -- Device only supports horizontal swing on/off. Any non-fixed value enables it.
  local enable_swing = (mode ~= "fixed" and mode ~= "off")
  return confirmed({ swing = enable_swing },
    client:set_property(SIID_FAN, PIID_SWING, enable_swing, "swing"))
end

function M.set_oscillation_angle(client, angle)
  angle = math.max(30, math.min(120, math.floor(tonumber(angle) or 90)))
  return confirmed({ angle = angle },
    client:set_property(SIID_FAN, PIID_ANGLE, angle, "angle"))
end

function M.set_power_off_timer(client, minutes)
  minutes = math.max(0, math.min(600, math.floor(tonumber(minutes) or 0)))
  local seconds = minutes * 60
  return confirmed({ ["power-off-delay"] = seconds },
    client:set_property(SIID_FAN, PIID_POWER_OFF_DELAY, seconds, "power-off-delay"))
end

function M.set_mode(client, mode_label)
  local code = LABEL_TO_MODE_CODE[mode_label]
  if not code then return nil, "unknown mode: " .. tostring(mode_label) end
  return confirmed({ ["fan-mode"] = code },
    client:set_property(SIID_FAN, PIID_FAN_MODE, code, "fan-mode"))
end

function M.set_child_lock(client, state)
  local value = state == "locked"
  return confirmed({ lock = value },
    client:set_property(SIID_LOCK, PIID_LOCK, value, "lock"))
end

function M.set_alarm_buzzer(client, state)
  local value = state == "on"
  return confirmed({ alarm = value },
    client:set_property(SIID_ALARM, PIID_ALARM, value, "alarm"))
end

return M
