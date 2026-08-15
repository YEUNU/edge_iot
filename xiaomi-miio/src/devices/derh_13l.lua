--[[
  xiaomi.derh.13l — Xiaomi Smart Dehumidifier 13L, v2 mapping.

  Standard caps:
    switch                          <- siid=2 piid=1
    mode {Smart,Sleep,Drying}       <- siid=2 piid=3
    relativeHumidityMeasurement     <- siid=3 piid=1
    temperatureMeasurement          <- siid=3 piid=2
  Custom caps (namespace earthpanel38939):
    targetHumidity (30..70 %)       <- siid=2 piid=5
    childLock                       <- siid=6 piid=1
    alarmBuzzer                     <- siid=4 piid=1
    indicatorLightMode {off,dim,bright} <- siid=5 piid=2 (0=Close→off, 1=Half→dim, 2=Full→bright)
    dryAfterOff {on,off}            <- siid=8 piid=1
    dryRemainingMinutes (0..720)    <- siid=8 piid=3 (read-only)
    deviceFault                     <- siid=2 piid=2
    isWarmingUp                     <- siid=7 piid=3 (read-only bool)
]]

local capabilities = require "st.capabilities"
local events = require "devices.events"

local M = {}
local NS = "earthpanel38939"
local cap_targetHumidity = capabilities[NS .. ".targetHumidity"]
local cap_childLock      = capabilities[NS .. ".childLock"]
local cap_alarmBuzzer    = capabilities[NS .. ".alarmBuzzer"]
local cap_indicatorMode  = capabilities[NS .. ".indicatorLightMode"]
local cap_deviceFault    = capabilities[NS .. ".deviceFault"]
local cap_filterMaintenance = capabilities[NS .. ".filterMaintenance"]

local SIID_DERH = 2
local PIID_POWER = 1
local PIID_FAULT = 2
local PIID_MODE  = 3
local PIID_TARGET = 5

local SIID_ENV = 3
local PIID_HUM = 1
local PIID_TEMP = 2

local SIID_ALARM = 4
local PIID_ALARM = 1

local SIID_LED = 5
local PIID_LED_MODE = 2

local SIID_LOCK = 6
local PIID_LOCK = 1

local SIID_WARMUP = 7
local PIID_WARMUP = 3

local SIID_DELAY = 8
local PIID_DELAY_ON = 1
local PIID_DELAY_REMAIN = 3

local MODE_LABELS = { [0] = "스마트", [1] = "수면", [2] = "옷 건조" }
local LABEL_TO_MODE_CODE = { ["스마트"] = 0, ["수면"] = 1, ["옷 건조"] = 2 }

local FAULT_LABELS = {
  [0] = "noFault", [1] = "waterFull", [2] = "sensorFault1", [3] = "sensorFault2",
  [4] = "commFault1", [5] = "filterClean", [6] = "defrost", [7] = "fanMotor",
  [8] = "overload", [9] = "lackOfRefrigerant",
}

local LED_TO_MODE = { [0] = "off", [1] = "dim", [2] = "bright" }
local LED_FROM_MODE = { off = 0, dim = 1, bright = 2 }

M.supported_modes = { "스마트", "수면", "옷 건조" }
M.uses_filter_maintenance = true

M.refresh_props = {
  { siid = SIID_DERH,  piid = PIID_POWER,    did = "power" },
  { siid = SIID_DERH,  piid = PIID_MODE,     did = "mode" },
  { siid = SIID_DERH,  piid = PIID_FAULT,    did = "fault" },
  { siid = SIID_DERH,  piid = PIID_TARGET,   did = "target" },
  { siid = SIID_ENV,   piid = PIID_HUM,      did = "humidity" },
  { siid = SIID_ENV,   piid = PIID_TEMP,     did = "temperature" },
  { siid = SIID_ALARM, piid = PIID_ALARM,    did = "alarm" },
  { siid = SIID_LED,   piid = PIID_LED_MODE, did = "led" },
  { siid = SIID_LOCK,  piid = PIID_LOCK,     did = "lock" },
}

local function select_props(wanted)
  local selected = {}
  for _, prop in ipairs(M.refresh_props) do
    if wanted[prop.did] then selected[#selected + 1] = prop end
  end
  return selected
end

M.core_props = select_props{
  power = true, mode = true, fault = true, target = true, humidity = true,
}
M.aux_props = select_props{
  temperature = true, alarm = true, led = true, lock = true,
}

local function confirmed(expected, ok, err)
  if not ok then return nil, err, expected end
  return true, nil, expected
end

local function emit_supported_modes(device)
  events.emit(device, capabilities.mode,
    capabilities.mode.supportedModes(M.supported_modes, { visibility = { displayed = false } }))
  if cap_filterMaintenance then
    events.emit(device, cap_filterMaintenance, cap_filterMaintenance.status("ready"))
  end
end

function M.on_added(device) emit_supported_modes(device) end
function M.on_init(device)  emit_supported_modes(device) end

function M.apply_state(device, p)
  local power = p["power"]
  if power ~= nil then
    events.emit(device, capabilities.switch,
      power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end

  local mode = p["mode"]
  if mode ~= nil and MODE_LABELS[mode] then
    events.emit(device, capabilities.mode, capabilities.mode.mode(MODE_LABELS[mode]))
  end

  local fault = p["fault"]
  if fault ~= nil and cap_deviceFault then
    local fault_label = FAULT_LABELS[fault]
    if fault_label then
      events.emit(device, cap_deviceFault, cap_deviceFault.fault(fault_label))
    else
      device.log.warn("unknown dehumidifier fault code: " .. tostring(fault))
    end
  end

  local target = p["target"]
  if target ~= nil and cap_targetHumidity then
    events.emit(device, cap_targetHumidity,
      cap_targetHumidity.targetHumidity({ value = target, unit = "%" }))
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

  local alarm = p["alarm"]
  if alarm ~= nil and cap_alarmBuzzer then
    events.emit(device, cap_alarmBuzzer, cap_alarmBuzzer.buzzer(alarm and "on" or "off"))
  end

  local led = p["led"]
  if led ~= nil and cap_indicatorMode then
    events.emit(device, cap_indicatorMode,
      cap_indicatorMode.indicator(LED_TO_MODE[led] or "off"))
  end

  local lock = p["lock"]
  if lock ~= nil and cap_childLock then
    events.emit(device, cap_childLock, cap_childLock.lock(lock and "locked" or "unlocked"))
  end

end

function M.set_switch(client, on)
  local value = on and true or false
  return confirmed({ power = value },
    client:set_property(SIID_DERH, PIID_POWER, value, "power"))
end

function M.set_mode(client, mode_label)
  local code = LABEL_TO_MODE_CODE[mode_label]
  if not code then return nil, "unknown mode: " .. tostring(mode_label) end
  return confirmed({ mode = code },
    client:set_property(SIID_DERH, PIID_MODE, code, "mode"))
end

function M.set_target_humidity(client, humidity)
  humidity = math.max(30, math.min(70, math.floor(humidity)))
  return confirmed({ target = humidity },
    client:set_property(SIID_DERH, PIID_TARGET, humidity, "target"))
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

function M.set_indicator(client, mode)
  local code = LED_FROM_MODE[mode]
  if not code then return nil, "unknown indicator mode: " .. tostring(mode) end
  return confirmed({ led = code },
    client:set_property(SIID_LED, PIID_LED_MODE, code, "led"))
end

function M.reset_filter(client)
  return confirmed({}, client:action(SIID_WARMUP, 3, {}, "reset-filter"))
end

return M
