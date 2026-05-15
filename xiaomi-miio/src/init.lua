--[[
  Xiaomi miIO/MiOT LAN driver — entry point.
]]

local log = require "log"
log.info("xiaomi-miio init.lua loading")

local capabilities = require "st.capabilities"
local Driver = require "st.driver"

local devices_config = require "devices_config"
local Client = require "miio.client"
local discovery = require "discovery"
local cmds = require "command_handlers"

local handler_modules = {
  fan_za5   = require "devices.fan_za5",
  airp_cpa4 = require "devices.airp_cpa4",
  derh_13l  = require "devices.derh_13l",
}

local NS = "earthpanel38939"
local function safe_cap(id)
  local ok, c = pcall(function() return capabilities[id] end)
  if ok and c then return c end
  log.warn("custom cap " .. id .. " unavailable")
  return nil
end
local cap_childLock      = safe_cap(NS .. ".childLock")
local cap_alarmBuzzer    = safe_cap(NS .. ".alarmBuzzer")
local cap_indicatorMode  = safe_cap(NS .. ".indicatorLightMode")
local cap_targetHumidity = safe_cap(NS .. ".targetHumidity")
local cap_dryAfterOff    = safe_cap(NS .. ".dryAfterOff")

local POLL_INTERVAL_S = 60

local function find_config(dni)
  for _, entry in ipairs(devices_config) do
    if entry.dni == dni then return entry end
  end
  return nil
end

local function attach(device)
  local cfg = find_config(device.device_network_id)
  if not cfg then
    device.log.error("no devices_config entry for dni=" .. device.device_network_id)
    return false
  end
  local handler = handler_modules[cfg.handler]
  if not handler then
    device.log.error("unknown handler: " .. tostring(cfg.handler))
    return false
  end
  -- Air purifier is slow when powered off; give it more headroom.
  local timeout_s = (cfg.handler == "airp_cpa4") and 10 or 6
  local client = Client.new{ ip = cfg.ip, token = cfg.token, timeout_s = timeout_s }
  device:set_field("client", client)
  device:set_field("handler_module", handler)
  device:set_field("config", cfg)
  return true
end

local function device_init(driver, device)
  device.log.info("init " .. device.device_network_id)
  if not attach(device) then return end
  local handler = device:get_field("handler_module")
  if handler and handler.on_init then handler.on_init(device) end
  cmds.refresh(driver, device)
  device.thread:call_on_schedule(
    POLL_INTERVAL_S,
    function() cmds.refresh(driver, device) end,
    device.id .. "_poll"
  )
end

local function device_added(driver, device)
  device.log.info("added " .. device.device_network_id)
  if attach(device) then
    local handler = device:get_field("handler_module")
    if handler.on_added then handler.on_added(device) end
    cmds.refresh(driver, device)
  end
end

local function device_removed(_, device)
  device.log.info("removed " .. device.device_network_id)
end

local capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = cmds.refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME]  = cmds.switch_on,
    [capabilities.switch.commands.off.NAME] = cmds.switch_off,
  },
  [capabilities.fanSpeed.ID] = {
    [capabilities.fanSpeed.commands.setFanSpeed.NAME] = cmds.set_fan_speed,
  },
  [capabilities.fanSpeedPercent.ID] = {
    [capabilities.fanSpeedPercent.commands.setPercent.NAME] = cmds.set_fan_speed_percent,
  },
  [capabilities.mode.ID] = {
    [capabilities.mode.commands.setMode.NAME] = cmds.set_mode,
  },
  [capabilities.fanOscillationMode.ID] = {
    [capabilities.fanOscillationMode.commands.setFanOscillationMode.NAME] = cmds.set_oscillation_mode,
  },
  [capabilities.windMode.ID] = {
    [capabilities.windMode.commands.setWindMode.NAME] = cmds.set_wind_mode,
  },
  [capabilities.switchLevel.ID] = {
    [capabilities.switchLevel.commands.setLevel.NAME] = cmds.set_switch_level,
  },
}

if cap_childLock then
  capability_handlers[cap_childLock.ID] = {
    ["setLock"] = cmds.set_child_lock,
    ["lock"]    = cmds.child_lock,
    ["unlock"]  = cmds.child_unlock,
  }
end
if cap_alarmBuzzer then
  capability_handlers[cap_alarmBuzzer.ID] = {
    ["setBuzzer"] = cmds.set_alarm_buzzer,
    ["buzzerOn"]  = cmds.buzzer_on,
    ["buzzerOff"] = cmds.buzzer_off,
  }
end
if cap_indicatorMode then
  capability_handlers[cap_indicatorMode.ID] = {
    ["setIndicator"] = cmds.set_indicator,
  }
end
if cap_targetHumidity then
  capability_handlers[cap_targetHumidity.ID] = {
    ["setTargetHumidity"] = cmds.set_target_humidity,
  }
end
if cap_dryAfterOff then
  capability_handlers[cap_dryAfterOff.ID] = {
    ["setDryAfterOff"] = cmds.set_dry_after_off,
    ["enable"]         = cmds.dry_after_off_enable,
    ["disable"]        = cmds.dry_after_off_disable,
  }
end

local driver = Driver("xiaomi-miio", {
  discovery = discovery.handle,
  lifecycle_handlers = {
    init    = device_init,
    added   = device_added,
    removed = device_removed,
  },
  capability_handlers = capability_handlers,
})

log.info("xiaomi-miio driver:run()")
driver:run()
