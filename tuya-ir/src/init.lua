--[[
  Tuya IR AC driver entry point. Cloud-based (HTTPS to Tuya OpenAPI).
  Per-device credentials (accessId/Secret/deviceId/region) come from
  SmartThings device settings — no secrets in source.
]]

local log = require "log"
log.info("tuya-ir init.lua loading")

local capabilities = require "st.capabilities"
local Driver = require "st.driver"

local Client = require "tuya.client"
local ac = require "tuya.ac"
local discovery = require "discovery"
local cmds = require "command_handlers"

local POLL_INTERVAL_S = 60

local function prefs_complete(p)
  return p and type(p.accessId) == "string" and #p.accessId >= 4
     and type(p.accessSecret) == "string" and #p.accessSecret >= 4
     and type(p.deviceId) == "string" and #p.deviceId >= 16
     and type(p.region) == "string"
end

local function attach(device)
  local p = device.preferences or {}
  if not prefs_complete(p) then
    device.log.info("missing Tuya preferences; idle until configured")
    device:offline()
    device:set_field("client", nil)
    device:set_field("tuya_device_id", nil)
    return false
  end
  local client = Client.new{
    access_id = p.accessId,
    access_secret = p.accessSecret,
    region = p.region,
  }
  device:set_field("client", client)
  device:set_field("tuya_device_id", p.deviceId)
  return true
end

local function emit_supported(device)
  device:emit_event(capabilities.airConditionerMode.supportedAcModes(
    ac.SUPPORTED_ST_MODES, { visibility = { displayed = false } }))
  device:emit_event(capabilities.airConditionerFanMode.supportedAcFanModes(
    ac.SUPPORTED_ST_FANS, { visibility = { displayed = false } }))
end

local function schedule_poll(driver, device)
  if device:get_field("poll_scheduled") then return end
  device:set_field("poll_scheduled", true)
  device.thread:call_on_schedule(
    POLL_INTERVAL_S,
    function() cmds.refresh(driver, device) end,
    device.id .. "_poll"
  )
end

local function device_init(driver, device)
  device.log.info("init " .. device.device_network_id)
  emit_supported(device)
  if attach(device) then
    cmds.refresh(driver, device)
    schedule_poll(driver, device)
  end
end

local function device_added(driver, device)
  device.log.info("added " .. device.device_network_id)
  emit_supported(device)
  if attach(device) then
    cmds.refresh(driver, device)
    schedule_poll(driver, device)
  end
end

local function device_info_changed(driver, device, _, old_prefs)
  local p = device.preferences or {}
  local op = old_prefs or {}
  if op.accessId ~= p.accessId or op.accessSecret ~= p.accessSecret
  or op.region   ~= p.region   or op.deviceId     ~= p.deviceId then
    device.log.info("preferences changed, re-attaching")
    if attach(device) then
      cmds.refresh(driver, device)
      schedule_poll(driver, device)
    end
  end
end

local function device_removed(_, device)
  device.log.info("removed " .. device.device_network_id)
end

local driver = Driver("tuya-ir", {
  discovery = discovery.handle,
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    infoChanged = device_info_changed,
    removed     = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = cmds.refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME]  = cmds.switch_on,
      [capabilities.switch.commands.off.NAME] = cmds.switch_off,
    },
    [capabilities.airConditionerMode.ID] = {
      [capabilities.airConditionerMode.commands.setAirConditionerMode.NAME] = cmds.set_ac_mode,
    },
    [capabilities.airConditionerFanMode.ID] = {
      [capabilities.airConditionerFanMode.commands.setFanMode.NAME] = cmds.set_fan_mode,
    },
    [capabilities.thermostatCoolingSetpoint.ID] = {
      [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = cmds.set_cooling_setpoint,
    },
  },
})

log.info("tuya-ir driver:run()")
driver:run()
