--[[
  zhimi.airp.cpa4 — Mi Air Purifier 4 Compact, v2 mapping.

  Standard caps:
    switch                  <- siid=2 piid=1
    mode {Auto,Sleep,Favorite} <- siid=2 piid=4
    dustSensor.fineDustLevel <- siid=3 piid=4
    filterState              <- siid=4 piid=1 (filter-life %; reset command → siid=4 aiid=1)
    fanSpeed (0..14)         <- siid=9 piid=11 favorite-level
  Custom caps (namespace earthpanel38939):
    childLock        <- siid=8 piid=1 (lock bool)
    alarmBuzzer      <- siid=6 piid=1 (alarm bool)
    indicatorLightMode {off,dim,bright} <- siid=13 piid=2 (Close→off, Bright→dim, Brightest→bright)
    deviceFault {noFault,motorStuck,sensorLost} <- siid=2 piid=2
]]

local capabilities = require "st.capabilities"
local events = require "devices.events"
local alerts = require "alerts"

local M = {}
local NS = "earthpanel38939"
local cap_childLock     = capabilities[NS .. ".childLock"]
local cap_alarmBuzzer   = capabilities[NS .. ".alarmBuzzer"]
local cap_indicatorMode = capabilities[NS .. ".indicatorLightMode"]
local cap_deviceFault   = capabilities[NS .. ".deviceFault"]
local cap_filterAlert = capabilities[NS .. ".filterAlert"]
local cap_favoriteLevel = capabilities[NS .. ".airPurifierFavoriteLevel"]

local SIID_AIRP = 2
local PIID_POWER = 1
local PIID_FAULT = 2
local PIID_MODE  = 4

local SIID_ENV = 3
local PIID_PM25 = 4

local SIID_FILTER = 4
local PIID_FILTER_LIFE = 1
local PIID_FILTER_USED_TIME = 3
local PIID_FILTER_LEFT_TIME = 4

local SIID_ALARM = 6
local PIID_ALARM = 1

local SIID_LOCK = 8
local PIID_LOCK = 1

local SIID_SCREEN = 13
local PIID_BRIGHT = 2

local SIID_CUSTOM = 9
local PIID_FAVORITE_LEVEL = 11

local MODE_LABELS = { [0] = "자동", [1] = "수면", [2] = "즐겨찾기" }
local LABEL_TO_MODE_CODE = { ["자동"] = 0, ["수면"] = 1, ["즐겨찾기"] = 2 }

M.supported_modes = { "자동", "수면", "즐겨찾기" }

local FAULT_LABELS = { [0] = "noFault", [2] = "motorStuck", [3] = "sensorLost" }
local BRIGHT_TO_LIGHT_MODE = { [0] = "off", [1] = "dim", [2] = "bright" }
local LIGHT_MODE_TO_BRIGHT = { off = 0, dim = 1, bright = 2 }

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
  { siid = SIID_FILTER,  piid = PIID_FILTER_USED_TIME, did = "filter-used-time" },
  { siid = SIID_FILTER,  piid = PIID_FILTER_LEFT_TIME, did = "filter-left-time" },
  { siid = SIID_ALARM,   piid = PIID_ALARM,       did = "alarm" },
  { siid = SIID_LOCK,    piid = PIID_LOCK,        did = "lock" },
  { siid = SIID_SCREEN,  piid = PIID_BRIGHT,      did = "brightness" },
  { siid = SIID_CUSTOM,  piid = PIID_FAVORITE_LEVEL, did = "favorite-level" },
}

local function select_props(wanted)
  local selected = {}
  for _, prop in ipairs(M.refresh_props) do
    if wanted[prop.did] then selected[#selected + 1] = prop end
  end
  return selected
end

M.core_props = select_props{
  power = true, mode = true, fault = true, pm25 = true,
  ["filter-life"] = true, ["favorite-level"] = true,
}
M.aux_props = select_props{
  ["filter-used-time"] = true, ["filter-left-time"] = true,
  alarm = true, lock = true, brightness = true,
}

local function confirmed(expected, ok, err)
  if not ok then return nil, err, expected end
  return true, nil, expected
end

local function emit_supported_modes(device)
  events.emit(device, capabilities.mode,
    capabilities.mode.supportedModes(M.supported_modes, { visibility = { displayed = false } }))
  events.emit(device, capabilities.filterState,
    capabilities.filterState.supportedFilterCommands(
      { "resetFilter" }, { visibility = { displayed = false } }))
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

  local pm25 = p["pm25"]
  if pm25 ~= nil then
    events.emit(device, capabilities.fineDustSensor, capabilities.fineDustSensor.fineDustLevel(pm25))
  end

  local life = p["filter-life"]
  if type(life) == "number" and life >= 0 and life <= 100 then
    events.emit(device, capabilities.filterState,
      capabilities.filterState.filterLifeRemaining({ value = life, unit = "%" }))
    -- A latched maintenance condition avoids repeat alerts as the reported
    -- percentage fluctuates near the threshold. Missing/invalid reads cannot
    -- clear it; only a confirmed reading above 15% rearms the notification.
    local previous
    if type(device.get_field) == "function" then
      previous = device:get_field("xiaomi_filter_alert_status")
    end
    if previous == nil and cap_filterAlert and type(device.get_latest_state) == "function" then
      previous = device:get_latest_state("main", cap_filterAlert.ID, "status")
    end
    local status = "normal"
    if life <= 10 or (previous == "replace" and life <= 15) then
      status = "replace"
    end
    if previous ~= status and type(device.set_field) == "function" then
      device:set_field("xiaomi_filter_alert_status", status, { persist = true })
    end
    if cap_filterAlert then
      events.emit_changed(device, cap_filterAlert, "status", status,
        cap_filterAlert.status(status))
    end
    alerts.report(device, "filter", status, status == "replace"
      and "필터 수명이 10% 이하예요. 교체할 필터를 준비해 주세요." or nil)
  end

  local fault = p["fault"]
  if fault ~= nil and FAULT_LABELS[fault] then
    local message
    if fault == 2 then message = "모터 막힘이 감지됐어요. 기기 상태를 확인해 주세요." end
    if fault == 3 then message = "센서 연결 오류가 감지됐어요. 기기 상태를 확인해 주세요." end
    alerts.report(device, "fault", FAULT_LABELS[fault], message)
  end
  if fault ~= nil and cap_deviceFault then
    local fault_label = FAULT_LABELS[fault]
    if fault_label then
      events.emit_changed(device, cap_deviceFault, "fault", fault_label,
        cap_deviceFault.fault(fault_label))
    else
      device.log.warn("unknown air purifier fault code: " .. tostring(fault))
    end
  end

  local alarm = p["alarm"]
  if alarm ~= nil and cap_alarmBuzzer then
    events.emit(device, cap_alarmBuzzer, cap_alarmBuzzer.buzzer(alarm and "on" or "off"))
  end

  local lock = p["lock"]
  if lock ~= nil and cap_childLock then
    events.emit(device, cap_childLock, cap_childLock.lock(lock and "locked" or "unlocked"))
  end

  local bright = p["brightness"]
  if bright ~= nil then
    if cap_indicatorMode then
      events.emit(device, cap_indicatorMode,
        cap_indicatorMode.indicator(BRIGHT_TO_LIGHT_MODE[bright] or "off"))
    end
  end

  local favorite_level = p["favorite-level"]
  if favorite_level ~= nil and cap_favoriteLevel then
    local effective = (power == false) and 0 or favorite_level
    events.emit(device, cap_favoriteLevel, cap_favoriteLevel.level(effective))
  end
end

function M.set_switch(client, on)
  local value = on and true or false
  return confirmed({ power = value },
    client:set_property(SIID_AIRP, PIID_POWER, value, "power"))
end

function M.set_mode(client, mode_label)
  local code = LABEL_TO_MODE_CODE[mode_label]
  if not code then return nil, "unknown mode: " .. tostring(mode_label) end
  return confirmed({ mode = code },
    client:set_property(SIID_AIRP, PIID_MODE, code, "mode"))
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
  local code = LIGHT_MODE_TO_BRIGHT[mode]
  if not code then return nil, "unknown indicator mode: " .. tostring(mode) end
  return confirmed({ brightness = code },
    client:set_property(SIID_SCREEN, PIID_BRIGHT, code, "brightness"))
end

function M.set_favorite_level(client, level)
  level = math.floor(tonumber(level) or 0)
  if level <= 0 then
    return confirmed({ power = false },
      client:set_property(SIID_AIRP, PIID_POWER, false, "power"))
  end
  level = math.max(1, math.min(14, level))
  local expected = { power = true, mode = 2, ["favorite-level"] = level }
  local ok, err = client:set_property(SIID_AIRP, PIID_POWER, true, "power")
  if not ok then return nil, err, expected end
  ok, err = client:set_property(SIID_AIRP, PIID_MODE, 2, "mode")
  if not ok then return nil, err, expected end
  return confirmed(expected,
    client:set_property(SIID_CUSTOM, PIID_FAVORITE_LEVEL, level, "favorite-level"))
end

function M.reset_filter(client)
  -- The MiOT action declares filter-used-time (piid=3) as its sole input.
  return confirmed({}, client:action(SIID_FILTER, 1, { 0 }, "reset-filter"))
end

return M
