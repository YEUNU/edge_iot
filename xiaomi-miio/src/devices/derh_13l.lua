--[[
  xiaomi.derh.13l — Xiaomi Smart Dehumidifier 13L, v2 mapping.

  Standard caps:
    switch                          <- siid=2 piid=1
    mode {Smart,Sleep,Drying}       <- siid=2 piid=3
    relativeHumidityMeasurement     <- siid=3 piid=1
    temperatureMeasurement          <- siid=3 piid=2
  Custom caps (namespace earthpanel38939):
    targetHumidity (40..70 %)       <- siid=2 piid=5 (manual operating range)
    childLock                       <- siid=6 piid=1
    alarmBuzzer                     <- siid=4 piid=1
    indicatorLightMode {off,dim,bright} <- siid=5 piid=2 (0=Close→off, 1=Half→dim, 2=Full→bright)
    dryAfterOff {on,off}            <- siid=7 piid=1
    dryRemainingMinutes (0..40)     <- siid=7 piid=2 (seconds, read-only)
    powerOffTimer (0..720 minutes)  <- siid=8 piid=1/2/3
    deviceFault                     <- siid=2 piid=2
    isWarmingUp                     <- siid=7 piid=3 (read-only bool)
]]

local capabilities = require "st.capabilities"
local events = require "devices.events"
local alerts = require "alerts"
local validation = require "devices.validation"

local M = {}
local NS = "earthpanel38939"
local cap_targetHumidity = capabilities[NS .. ".targetHumidity"]
local cap_currentHumidity = capabilities[NS .. ".currentHumidity"]
local cap_childLock      = capabilities[NS .. ".childLock"]
local cap_alarmBuzzer    = capabilities[NS .. ".alarmBuzzer"]
local cap_indicatorMode  = capabilities[NS .. ".indicatorLightMode"]
local cap_deviceFault    = capabilities[NS .. ".deviceFault"]
local cap_filterMaintenance = capabilities[NS .. ".filterMaintenance"]
local cap_dryAfterOff = capabilities[NS .. ".dryAfterOff"]
local cap_dryRemaining = capabilities[NS .. ".dryRemainingMinutes"]
local cap_warmingUp = capabilities[NS .. ".isWarmingUp"]
local cap_timer = capabilities[NS .. ".powerOffTimer"]

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

local MODE_LABELS = { [0] = "스마트", [1] = "수면", [2] = "옷 건조" }
local LABEL_TO_MODE_CODE = { ["스마트"] = 0, ["수면"] = 1, ["옷 건조"] = 2 }

local FAULT_LABELS = {
  [0] = "noFault", [1] = "waterFull", [2] = "sensorFault1", [3] = "sensorFault2",
  [4] = "commFault1", [5] = "filterClean", [6] = "defrost", [7] = "fanMotor",
  [8] = "overload", [9] = "lackOfRefrigerant",
}

local FAULT_MESSAGES = {
  [1] = "물통이 가득 찼어요. 물통을 비우고 다시 장착해 주세요.",
  [2] = "센서 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
  [3] = "두 번째 센서 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
  [4] = "내부 통신 오류가 감지됐어요. 기기 상태를 확인해 주세요.",
  [5] = "필터 청소가 필요해요. 필터를 확인해 주세요.",
  [7] = "팬 모터 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
  [8] = "과부하가 감지됐어요. 기기 상태를 확인해 주세요.",
  [9] = "냉매 부족이 감지됐어요. 기기 점검이 필요해요.",
}

local LED_TO_MODE = { [0] = "off", [1] = "dim", [2] = "bright" }
local LED_FROM_MODE = { off = 0, dim = 1, bright = 2 }

M.supported_modes = { "스마트", "수면", "옷 건조" }
M.uses_filter_maintenance = true

-- Mode changes can also change the device's target humidity. Read it back
-- without guessing a preset or overwriting a humidity chosen by the user.
M.confirmation_dependencies = {
  mode = { "target" }, target = { "mode" },
  power = { "dry-left-seconds", "warming-up" },
  ["timer-enabled"] = { "timer-minutes", "timer-remaining" },
}

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
  { siid = 7, piid = 1, did = "dry-after-off" },
  { siid = 7, piid = 2, did = "dry-left-seconds" },
  { siid = 7, piid = 3, did = "warming-up" },
  { siid = 8, piid = 1, did = "timer-enabled" },
  { siid = 8, piid = 2, did = "timer-minutes" },
  { siid = 8, piid = 3, did = "timer-remaining" },
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
  ["dry-left-seconds"] = true, ["warming-up"] = true,
  ["timer-enabled"] = true, ["timer-remaining"] = true,
}
M.aux_props = select_props{
  temperature = true, alarm = true, led = true, lock = true,
  ["dry-after-off"] = true, ["timer-minutes"] = true,
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
  if p["dry-after-off"] ~= nil and cap_dryAfterOff then
    events.emit(device, cap_dryAfterOff,
      cap_dryAfterOff.dryAfterOff(p["dry-after-off"] and "on" or "off"))
  end
  if p["dry-left-seconds"] ~= nil and cap_dryRemaining then
    events.emit(device, cap_dryRemaining,
      cap_dryRemaining.remainingMinutes({ value = math.ceil(p["dry-left-seconds"] / 60), unit = "min" }))
  end
  if p["warming-up"] ~= nil and cap_warmingUp then
    events.emit(device, cap_warmingUp, cap_warmingUp.warmingUp(p["warming-up"] and "yes" or "no"))
  end
  if cap_timer and (p["timer-enabled"] == false or p["timer-remaining"] ~= nil) then
    events.emit(device, cap_timer, cap_timer.minutes({
      value = p["timer-enabled"] == false and 0 or p["timer-remaining"], unit = "min" }))
  end
  local power = p["power"]
  if power ~= nil then
    events.emit(device, capabilities.switch,
      power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end

  local mode = p["mode"]
  if mode ~= nil and cap_targetHumidity then
    events.emit(device, cap_targetHumidity,
      cap_targetHumidity.adjustable((mode == 0 or mode == 1) and "yes" or "no"))
  end
  if mode ~= nil and MODE_LABELS[mode] then
    events.emit(device, capabilities.mode, capabilities.mode.mode(MODE_LABELS[mode]))
  end

  local fault = p["fault"]
  if fault ~= nil and FAULT_LABELS[fault] then
    alerts.report(device, "fault", FAULT_LABELS[fault], FAULT_MESSAGES[fault])
  end
  if fault ~= nil and cap_deviceFault then
    local fault_label = FAULT_LABELS[fault]
    if fault_label then
      events.emit_changed(device, cap_deviceFault, "fault", fault_label,
        cap_deviceFault.fault(fault_label))
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
    if cap_currentHumidity then
      events.emit(device, cap_currentHumidity, cap_currentHumidity.humidity(hum))
    end
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
  local value, err = validation.integer(humidity, 40, 70)
  if not value then return nil, err end
  local mode, read_err = validation.read(client, SIID_DERH, PIID_MODE, "mode")
  if mode == nil then return nil, read_err end
  if mode ~= 0 and mode ~= 1 then
    return nil, "target humidity is adjustable only in smart or sleep mode"
  end
  return confirmed({ target = value },
    client:set_property(SIID_DERH, PIID_TARGET, value, "target"))
end

function M.set_dry_after_off(client, state)
  if state ~= "on" and state ~= "off" then return nil, "invalid drying setting" end
  return confirmed({ ["dry-after-off"] = state == "on" },
    client:set_property(7, 1, state == "on", "dry-after-off"))
end

function M.set_power_off_timer(client, minutes)
  local value, err = validation.integer(minutes, 0, 720)
  if not value then return nil, err end
  if value == 0 then
    return confirmed({ ["timer-enabled"] = false },
      client:set_property(8, 1, false, "timer-enabled"))
  end
  local enabled, read_err = validation.read(client, 8, 1, "timer-enabled")
  if enabled == nil then return nil, read_err end
  -- Firmware 2.2.2 resets the duration to 60 minutes when enabling the timer.
  -- Enable first, then set the requested duration; otherwise every request
  -- silently becomes one hour despite both writes reporting success.
  if not enabled then
    local ok, enable_err = client:set_property(8, 1, true, "timer-enabled")
    if not ok then return nil, enable_err end
  end
  local ok, set_err = client:set_property(8, 2, value, "timer-minutes")
  if not ok and not enabled then
    local restored, restore_err = client:set_property(8, 1, false, "timer-enabled")
    if not restored then set_err = tostring(set_err) .. "; timer cancel failed: " .. tostring(restore_err) end
  end
  return confirmed({ ["timer-enabled"] = true, ["timer-minutes"] = value }, ok, set_err)
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
