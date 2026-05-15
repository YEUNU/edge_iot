--[[
  zhimi.airp.cpa4 — Mi Air Purifier 4 Compact, v2 mapping.

  Standard caps:
    switch                  <- siid=2 piid=1
    mode {Auto,Sleep,Favorite} <- siid=2 piid=4
    dustSensor.fineDustLevel <- siid=3 piid=4
    airQualitySensor         <- derived from PM2.5
    filterStatus             <- siid=4 piid=1 (filter-life %; replace when <10)
    switchLevel              <- siid=13 piid=2 brightness (0=Close,1=Bright,2=Brightest → 0/50/100)
  Custom caps (namespace earthpanel38939):
    childLock        <- siid=8 piid=1 (lock bool)
    alarmBuzzer      <- siid=6 piid=1 (alarm bool)
    indicatorLightMode {off,dim,bright} <- siid=13 piid=2 (Close→off, Bright→dim, Brightest→bright)
    deviceFault {noFault,motorStuck,sensorLost} <- siid=2 piid=2
]]

local capabilities = require "st.capabilities"

local M = {}
local NS = "earthpanel38939"
local cap_childLock     = capabilities[NS .. ".childLock"]
local cap_alarmBuzzer   = capabilities[NS .. ".alarmBuzzer"]
local cap_indicatorMode = capabilities[NS .. ".indicatorLightMode"]
local cap_deviceFault   = capabilities[NS .. ".deviceFault"]

local SIID_AIRP = 2
local PIID_POWER = 1
local PIID_FAULT = 2
local PIID_MODE  = 4

local SIID_ENV = 3
local PIID_PM25 = 4

local SIID_FILTER = 4
local PIID_FILTER_LIFE = 1

local SIID_ALARM = 6
local PIID_ALARM = 1

local SIID_LOCK = 8
local PIID_LOCK = 1

local SIID_SCREEN = 13
local PIID_BRIGHT = 2

local MODE_LABELS = { [0] = "자동", [1] = "수면", [2] = "즐겨찾기" }
local LABEL_TO_MODE_CODE = { ["자동"] = 0, ["수면"] = 1, ["즐겨찾기"] = 2 }

M.supported_modes = { "자동", "수면", "즐겨찾기" }

local FAULT_LABELS = { [0] = "noFault", [2] = "motorStuck", [3] = "sensorLost" }
local BRIGHT_TO_LIGHT_MODE = { [0] = "off", [1] = "dim", [2] = "bright" }
local LIGHT_MODE_TO_BRIGHT = { off = 0, dim = 1, bright = 2 }
local BRIGHT_TO_LEVEL = { [0] = 0, [1] = 50, [2] = 100 }

-- This device returns -9999 ("user ack timeout") when a single get_properties
-- request mixes properties from too many different services. Keep chunk_size
-- small enough that each request stays within 1–2 services.
M.chunk_size = 2

M.refresh_props = {
  { siid = SIID_AIRP,    piid = PIID_POWER,       did = "power" },
  { siid = SIID_AIRP,    piid = PIID_MODE,        did = "mode" },
  { siid = SIID_AIRP,    piid = PIID_FAULT,       did = "fault" },
  { siid = SIID_ENV,     piid = PIID_PM25,        did = "pm25" },
  { siid = SIID_FILTER,  piid = PIID_FILTER_LIFE, did = "filter-life" },
  { siid = SIID_ALARM,   piid = PIID_ALARM,       did = "alarm" },
  { siid = SIID_LOCK,    piid = PIID_LOCK,        did = "lock" },
  { siid = SIID_SCREEN,  piid = PIID_BRIGHT,      did = "brightness" },
}

local function pm25_to_aqi(c)
  if c == nil then return nil end
  local function lerp(c_lo, c_hi, i_lo, i_hi)
    return math.floor(((i_hi - i_lo) / (c_hi - c_lo)) * (c - c_lo) + i_lo + 0.5)
  end
  if c <= 12    then return lerp(0,     12,    0,   50) end
  if c <= 35.4  then return lerp(12.1,  35.4,  51,  100) end
  if c <= 55.4  then return lerp(35.5,  55.4,  101, 150) end
  if c <= 150.4 then return lerp(55.5,  150.4, 151, 200) end
  if c <= 250.4 then return lerp(150.5, 250.4, 201, 300) end
  if c <= 500.4 then return lerp(250.5, 500.4, 301, 500) end
  return 500
end

local function emit_supported_modes(device)
  device:emit_event(capabilities.mode.supportedModes(M.supported_modes, { visibility = { displayed = false } }))
end

function M.on_added(device) emit_supported_modes(device) end
function M.on_init(device)  emit_supported_modes(device) end

function M.apply_state(device, p)
  local power = p["power"]
  if power ~= nil then
    device:emit_event(power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end

  local mode = p["mode"]
  if mode ~= nil and MODE_LABELS[mode] then
    device:emit_event(capabilities.mode.mode(MODE_LABELS[mode]))
  end

  local pm25 = p["pm25"]
  if pm25 ~= nil then
    device:emit_event(capabilities.fineDustSensor.fineDustLevel(pm25))
    local aqi = pm25_to_aqi(pm25)
    if aqi then device:emit_event(capabilities.airQualitySensor.airQuality(aqi)) end
  end

  local life = p["filter-life"]
  if life ~= nil then
    device:emit_event(capabilities.filterState.filterLifeRemaining({ value = life, unit = "%" }))
  end

  local fault = p["fault"]
  if fault ~= nil and cap_deviceFault then
    device:emit_event(cap_deviceFault.fault(FAULT_LABELS[fault] or "noFault"))
  end

  local alarm = p["alarm"]
  if alarm ~= nil and cap_alarmBuzzer then
    device:emit_event(cap_alarmBuzzer.buzzer(alarm and "on" or "off"))
  end

  local lock = p["lock"]
  if lock ~= nil and cap_childLock then
    device:emit_event(cap_childLock.lock(lock and "locked" or "unlocked"))
  end

  local bright = p["brightness"]
  if bright ~= nil then
    if cap_indicatorMode then
      device:emit_event(cap_indicatorMode.indicator(BRIGHT_TO_LIGHT_MODE[bright] or "off"))
    end
    device:emit_event(capabilities.switchLevel.level(BRIGHT_TO_LEVEL[bright] or 0))
  end
end

function M.set_switch(client, on)
  return client:set_property(SIID_AIRP, PIID_POWER, on and true or false, "power")
end

function M.set_mode(client, mode_label)
  local code = LABEL_TO_MODE_CODE[mode_label]
  if not code then return nil, "unknown mode: " .. tostring(mode_label) end
  return client:set_property(SIID_AIRP, PIID_MODE, code, "mode")
end

function M.set_child_lock(client, state)
  return client:set_property(SIID_LOCK, PIID_LOCK, state == "locked", "lock")
end

function M.set_alarm_buzzer(client, state)
  return client:set_property(SIID_ALARM, PIID_ALARM, state == "on", "alarm")
end

function M.set_indicator(client, mode)
  local code = LIGHT_MODE_TO_BRIGHT[mode]
  if not code then return nil, "unknown indicator mode: " .. tostring(mode) end
  return client:set_property(SIID_SCREEN, PIID_BRIGHT, code, "brightness")
end

function M.set_switch_level(client, level)
  -- Map 0..33→off(0), 34..66→dim(1), 67..100→bright(2)
  local code
  if level <= 33 then code = 0
  elseif level <= 66 then code = 1
  else code = 2 end
  return client:set_property(SIID_SCREEN, PIID_BRIGHT, code, "brightness")
end

return M
