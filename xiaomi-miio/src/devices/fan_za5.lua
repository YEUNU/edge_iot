--[[
  zhimi.fan.za5 — Mi Smart Standing Fan 2 (DC inverter), v2 mapping.

  Standard caps:
    switch                       <- siid=2 piid=1 (power, bool)
    fanSpeed (0..4)              <- siid=2 piid=2 (fan-level 1..4; 0 = power off)
    fanSpeedPercent (0..100)     <- siid=2 piid=2 (mapped 1=25, 2=50, 3=75, 4=100)
    fanOscillationMode {fixed,horizontal} <- siid=2 piid=3 (horizontal swing bool)
    mode {Natural,Straight}      <- siid=2 piid=7 (0=Natural Wind, 1=Straight Wind)
    switchLevel                  <- siid=4 piid=3 (indicator brightness 0..100)
    relativeHumidityMeasurement  <- siid=7 piid=1
    temperatureMeasurement       <- siid=7 piid=7
  Custom caps (namespace: earthpanel38939):
    childLock {locked,unlocked}  <- siid=3 piid=1 (lock bool)
]]

local capabilities = require "st.capabilities"

local M = {}
local NS = "earthpanel38939"
local cap_childLock = capabilities[NS .. ".childLock"]

local SIID_FAN = 2
local PIID_POWER = 1
local PIID_LEVEL = 2
local PIID_SWING = 3
local PIID_FAN_MODE = 7

local SIID_LOCK = 3
local PIID_LOCK = 1
local SIID_INDICATOR = 4
local PIID_INDICATOR_BRIGHT = 3
local SIID_ENV = 7
local PIID_HUM = 1
local PIID_TEMP = 7

local MODE_LABELS = { [0] = "자연풍", [1] = "직선풍" }
local LABEL_TO_MODE_CODE = { ["자연풍"] = 0, ["직선풍"] = 1 }

M.supported_modes = { "자연풍", "직선풍" }

M.refresh_props = {
  { siid = SIID_FAN,        piid = PIID_POWER,           did = "power" },
  { siid = SIID_FAN,        piid = PIID_LEVEL,           did = "fan-level" },
  { siid = SIID_FAN,        piid = PIID_SWING,           did = "swing" },
  { siid = SIID_FAN,        piid = PIID_FAN_MODE,        did = "fan-mode" },
  { siid = SIID_LOCK,       piid = PIID_LOCK,            did = "lock" },
  { siid = SIID_INDICATOR,  piid = PIID_INDICATOR_BRIGHT,did = "indicator" },
  { siid = SIID_ENV,        piid = PIID_HUM,             did = "humidity" },
  { siid = SIID_ENV,        piid = PIID_TEMP,            did = "temperature" },
}

local SUPPORTED_OSCILLATION = { "fixed", "horizontal" }

local function emit_supported(device)
  device:emit_event(capabilities.mode.supportedModes(M.supported_modes, { visibility = { displayed = false } }))
  device:emit_event(capabilities.fanOscillationMode.supportedFanOscillationModes(SUPPORTED_OSCILLATION, { visibility = { displayed = false } }))
  device:emit_event(capabilities.fanOscillationMode.availableFanOscillationModes(SUPPORTED_OSCILLATION, { visibility = { displayed = false } }))
end

function M.on_added(device) emit_supported(device) end
function M.on_init(device)  emit_supported(device) end

local function level_to_pct(level) return ({ [1] = 25, [2] = 50, [3] = 75, [4] = 100 })[level] or 0 end
local function pct_to_level(pct)
  if pct <= 0 then return 0 end
  if pct <= 25 then return 1 end
  if pct <= 50 then return 2 end
  if pct <= 75 then return 3 end
  return 4
end

function M.apply_state(device, p)
  local power = p["power"]
  if power ~= nil then
    device:emit_event(power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end

  local level = p["fan-level"]
  if level ~= nil then
    local effective = (power == false) and 0 or level
    device:emit_event(capabilities.fanSpeed.fanSpeed(effective))
    device:emit_event(capabilities.fanSpeedPercent.percent(level_to_pct(effective)))
  end

  local swing = p["swing"]
  if swing ~= nil then
    device:emit_event(capabilities.fanOscillationMode.fanOscillationMode(
      swing and "horizontal" or "fixed"))
  end

  local fan_mode = p["fan-mode"]
  if fan_mode ~= nil and MODE_LABELS[fan_mode] then
    device:emit_event(capabilities.mode.mode(MODE_LABELS[fan_mode]))
  end

  local lock = p["lock"]
  if lock ~= nil and cap_childLock then
    device:emit_event(cap_childLock.lock(lock and "locked" or "unlocked"))
  end

  local indicator = p["indicator"]
  if indicator ~= nil then
    device:emit_event(capabilities.switchLevel.level(indicator))
  end

  local hum = p["humidity"]
  if hum ~= nil then
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(hum))
  end

  local temp = p["temperature"]
  if temp ~= nil then
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = temp, unit = "C" }))
  end
end

-- Setters
function M.set_switch(client, on)
  return client:set_property(SIID_FAN, PIID_POWER, on and true or false, "power")
end

function M.set_fan_speed(client, speed)
  if speed == 0 then return client:set_property(SIID_FAN, PIID_POWER, false, "power") end
  speed = math.max(1, math.min(4, speed))
  local ok, e = client:set_property(SIID_FAN, PIID_POWER, true, "power")
  if not ok then return nil, e end
  return client:set_property(SIID_FAN, PIID_LEVEL, speed, "fan-level")
end

function M.set_fan_speed_percent(client, pct)
  local level = pct_to_level(pct)
  return M.set_fan_speed(client, level)
end

function M.set_switch_level(client, level)
  level = math.max(0, math.min(100, level))
  return client:set_property(SIID_INDICATOR, PIID_INDICATOR_BRIGHT, level, "indicator")
end

function M.set_oscillation_mode(client, mode)
  -- Device only supports horizontal swing on/off. Any non-fixed value enables it.
  local enable_swing = (mode ~= "fixed" and mode ~= "off")
  return client:set_property(SIID_FAN, PIID_SWING, enable_swing, "swing")
end

function M.set_mode(client, mode_label)
  local code = LABEL_TO_MODE_CODE[mode_label]
  if not code then return nil, "unknown mode: " .. tostring(mode_label) end
  return client:set_property(SIID_FAN, PIID_FAN_MODE, code, "fan-mode")
end

function M.set_child_lock(client, state)
  return client:set_property(SIID_LOCK, PIID_LOCK, state == "locked", "lock")
end

return M
