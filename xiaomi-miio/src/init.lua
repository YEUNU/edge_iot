--[[
  Xiaomi miIO/MiOT LAN driver — entry point.

  Per-device IP and token come from the device's SmartThings settings panel
  (see `preferences` in each profile YAML). No secrets are baked into the
  driver source.
]]

local log = require "log"
log.info("xiaomi-miio init.lua loading")

local capabilities = require "st.capabilities"
local Driver = require "st.driver"

local models = require "models"
local Client = require "miio.client"
local discovery = require "discovery"
local cmds = require "command_handlers"

local handler_modules = {
  fan_za5   = require "devices.fan_za5",
  airp_cpa4 = require "devices.airp_cpa4",
  derh_13l  = require "devices.derh_13l",
}

local model_to_def = {}
for _, m in ipairs(models) do
  model_to_def[m.model] = m
end

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

local POLL_INTERVAL_S = 10

local function find_model_def(device)
  -- Prefer the model string on the device record; fall back to handler hint
  -- stored as a field during discovery.
  local m = device.model and model_to_def[device.model]
  if m then return m end
  return device:get_field("model_def")
end

local function prefs_complete(prefs)
  return prefs
     and type(prefs.deviceIp)    == "string" and #prefs.deviceIp    >= 7
     and type(prefs.deviceToken) == "string" and #prefs.deviceToken == 32
end

local function attach(device)
  local cfg = find_model_def(device)
  if not cfg then
    device.log.error("unknown model: " .. tostring(device.model))
    return false
  end
  device:set_field("model_def", cfg)

  local prefs = device.preferences or {}
  if not prefs_complete(prefs) then
    device.log.info("missing IP/token preferences; idle until configured")
    device:offline()
    device:set_field("client", nil)
    return false
  end

  local handler = handler_modules[cfg.handler]
  if not handler then
    device.log.error("no handler module for " .. cfg.handler)
    return false
  end

  -- Air purifier needs a slightly longer per-RPC timeout (slow when off).
  local timeout_s = (cfg.handler == "airp_cpa4") and 10 or 6
  local client = Client.new{ ip = prefs.deviceIp, token = prefs.deviceToken, timeout_s = timeout_s }
  device:set_field("client", client)
  device:set_field("handler_module", handler)
  return true
end

local function start_polling(driver, device)
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
  if not attach(device) then return end
  local handler = device:get_field("handler_module")
  if handler and handler.on_init then handler.on_init(device) end
  cmds.refresh(driver, device)
  start_polling(driver, device)
end

local function device_added(driver, device)
  device.log.info("added " .. device.device_network_id)
  -- Set the model_def regardless of preferences so we know which handler to use
  -- once the user fills them in.
  local cfg = find_model_def(device)
  if cfg then
    device:set_field("model_def", cfg)
    local handler = handler_modules[cfg.handler]
    if handler and handler.on_added then handler.on_added(device) end
  end
  if attach(device) then
    cmds.refresh(driver, device)
    start_polling(driver, device)
  end
end

local function device_info_changed(driver, device, _, old_prefs)
  -- Re-attach when the IP or token changes.
  local prefs = device.preferences or {}
  if (old_prefs or {}).deviceIp    ~= prefs.deviceIp
  or (old_prefs or {}).deviceToken ~= prefs.deviceToken then
    device.log.info("preferences changed, re-attaching")
    if attach(device) then
      cmds.refresh(driver, device)
      start_polling(driver, device)
    end
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
    init        = device_init,
    added       = device_added,
    infoChanged = device_info_changed,
    removed     = device_removed,
  },
  capability_handlers = capability_handlers,
})

log.info("xiaomi-miio driver:run()")
driver:run()
