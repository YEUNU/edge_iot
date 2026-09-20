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
local connection = require "connection"
local cmds = require "command_handlers"
local alerts = require "alerts"

local handler_modules = {
  fan_za5   = require "devices.fan_za5",
  airp_cpa4 = require "devices.airp_cpa4",
  derh_13l  = require "devices.derh_13l",
}

local model_to_def = {}
local handler_to_def = {}
for _, m in ipairs(models) do
  model_to_def[m.model] = m
  handler_to_def[m.handler] = m
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
local cap_oscillationAngle = safe_cap(NS .. ".fanOscillationDegrees")
local cap_powerOffTimer = safe_cap(NS .. ".powerOffTimer")
local cap_filterMaintenance = safe_cap(NS .. ".filterMaintenance")
local cap_dryAfterOff = safe_cap(NS .. ".dryAfterOff")
local cap_favoriteLevel = safe_cap(NS .. ".airPurifierFavoriteLevel")

local CORE_POLL_INTERVAL_S = 20
local AUX_POLL_INTERVAL_S = 300

local function find_model_def(device)
  -- Prefer the model string on the device record; fall back to handler hint
  -- selected on the generic setup record, then to the stored handler hint.
  local m = device.model and model_to_def[device.model]
  if m then return m end
  local discovered = device:get_field("local_connection")
  if discovered and model_to_def[discovered.model] then return model_to_def[discovered.model] end
  local selected = device.preferences and device.preferences.deviceModel
  if selected and handler_to_def[selected] then return handler_to_def[selected] end
  return device:get_field("model_def")
end

local function desired_profile(cfg, prefs)
  if prefs and prefs.showAdvanced == true then
    return cfg.advanced_profile
  end
  return cfg.profile
end

local prefs_complete = connection.complete

local function sync_device_metadata(device, cfg)
  if not cfg then return end
  local metadata = {
    profile = desired_profile(cfg, device.preferences or {}),
    model = cfg.model,
    manufacturer = "Xiaomi",
    vendor_provided_label = cfg.vendor_label,
  }
  if prefs_complete(connection.get(device)) then
    metadata.provisioning_state = "PROVISIONED"
  end
  device:try_update_metadata(metadata)
end

local function attach(device)
  -- The setup record is a hub-hosted UI, not an unreachable appliance.
  -- A model default alone must not turn missing onboarding credentials into
  -- an offline warning or disable its refresh/enrollment controls.
  if device.model == "xiaomi.setup" and not prefs_complete(connection.get(device)) then
    device:online()
    device:set_field("client", nil)
    return false
  end
  local cfg = find_model_def(device)
  if not cfg then
    device.log.error("unknown model: " .. tostring(device.model))
    return false
  end
  device:set_field("model_def", cfg)

  local prefs = connection.get(device)
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
  local client, client_err = Client.new{
    ip = prefs.deviceIp,
    token = prefs.deviceToken,
    timeout_s = timeout_s,
  }
  if not client then
    device.log.error("invalid miIO client settings: " .. tostring(client_err))
    device:offline()
    return false
  end
  device:set_field("client", client)
  device:set_field("handler_module", handler)
  return true
end

local function initialize_handler(device)
  local handler = device:get_field("handler_module")
  if handler and handler.on_init then handler.on_init(device) end
end

local function start_polling(driver, device)
  if not device:get_field("core_poll_scheduled") then
    device:set_field("core_poll_scheduled", true)
    device.thread:call_on_schedule(
      CORE_POLL_INTERVAL_S,
      function() cmds.refresh_core(driver, device) end,
      device.id .. "_core_poll"
    )
  end
  if not device:get_field("aux_poll_scheduled") then
    device:set_field("aux_poll_scheduled", true)
    device.thread:call_on_schedule(
      AUX_POLL_INTERVAL_S,
      function() cmds.refresh_aux(driver, device) end,
      device.id .. "_aux_poll"
    )
  end
end

local function device_init(driver, device)
  discovery.restore(driver, device)
  if device.model == "xiaomi.setup" then
    device:try_update_metadata({profile="xiaomi-setup.v1"})
    local cap = safe_cap("earthpanel38939.xiaomiLocalLink")
    if cap then device:emit_event(cap.status(device:get_field("enrollment_status") or "최초 샤오미 로그인이 필요합니다")) end
  end
  device.log.info("init " .. device.device_network_id)
  if alerts.is_endpoint(device) then
    device:try_update_metadata({ profile = alerts.PROFILE })
    alerts.initialize(driver, device)
    return
  end
  local cfg = find_model_def(device)
  if device.model == "xiaomi.setup" and not cfg then
    device.log.info("waiting for Xiaomi model/IP/token settings")
    device:online()
    return
  end
  if cfg then
    device:set_field("model_def", cfg)
    -- Package updates can change a profile ID even when its name is stable.
    -- Migrate existing physical devices too, so newly added alert capabilities
    -- are available without deleting devices or losing their routines.
    if prefs_complete(connection.get(device)) then
      sync_device_metadata(device, cfg)
    end
  end
  if not attach(device) then return end
  alerts.attach(driver, device)
  initialize_handler(device)
  cmds.refresh(driver, device)
  start_polling(driver, device)
end

local function device_added(driver, device)
  device.log.info("added " .. device.device_network_id)
  if alerts.is_endpoint(device) then
    alerts.initialize(driver, device)
    return
  end
  if device.model == "xiaomi.setup" and not prefs_complete(connection.get(device)) then
    device:online()
    return
  end
  -- Set the model_def regardless of preferences so we know which handler to use
  -- once the user fills them in.
  local cfg = find_model_def(device)
  if cfg then
    device:set_field("model_def", cfg)
  elseif device.model == "xiaomi.setup" then
    device:online()
  end
end

local function device_info_changed(driver, device, _, args)
  -- Re-attach when connection/model settings change and switch between the
  -- simple and advanced profiles without replacing the SmartThings device.
  local prefs = device.preferences or {}
  local old_prefs = args and args.old_st_store and args.old_st_store.preferences or {}
  local connection_changed = old_prefs.deviceIp ~= prefs.deviceIp
                          or old_prefs.deviceToken ~= prefs.deviceToken
  if old_prefs.deviceIp ~= prefs.deviceIp and connection.valid_ip(prefs.deviceIp) then
    local saved = device:get_field("local_connection") or {}
    saved = { ip = prefs.deviceIp, token = saved.token, did = saved.did, model = saved.model, preference_token = saved.preference_token }
    connection.save(device, saved)
  end
  local model_changed = old_prefs.deviceModel ~= prefs.deviceModel
  local advanced_changed = old_prefs.showAdvanced ~= prefs.showAdvanced
  local cfg = find_model_def(device)
  local setup_completed = device.model == "xiaomi.setup" and connection_changed

  if cfg and prefs_complete(connection.get(device)) and (model_changed or advanced_changed or setup_completed) then
    device:set_field("model_def", cfg)
    sync_device_metadata(device, cfg)
  end

  if connection_changed or model_changed then
    device.log.info("preferences changed, re-attaching")
    if attach(device) then
      alerts.attach(driver, device)
      initialize_handler(device)
      cmds.refresh(driver, device)
      start_polling(driver, device)
    end
  elseif advanced_changed and device:get_field("client") then
    -- Populate capabilities newly exposed by the advanced profile.
    initialize_handler(device)
    cmds.refresh(driver, device)
  end
end

local function device_removed(_, device)
  device.log.info("removed " .. device.device_network_id)
end

local capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = function(driver, device)
      if device.model == "xiaomi.setup" then
        discovery.scan(driver)
      else
        cmds.refresh(driver, device)
      end
    end,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME]  = cmds.switch_on,
    [capabilities.switch.commands.off.NAME] = cmds.switch_off,
  },
  -- Kept for devices that still have the earlier fan profile during an update.
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
  [capabilities.filterState.ID] = {
    [capabilities.filterState.commands.resetFilter.NAME] = cmds.reset_filter,
  },
}

local cap_latestAlert = safe_cap("earthpanel38939.latestAlert")
if cap_latestAlert then
  capability_handlers[cap_latestAlert.ID] = { sendTest = alerts.send_test }
end

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
if cap_oscillationAngle then
  capability_handlers[cap_oscillationAngle.ID] = {
    ["setDegrees"] = cmds.set_oscillation_angle,
  }
end
local cap_oscillationControl = safe_cap(NS .. ".fanOscillationControl")
if cap_oscillationControl then
  capability_handlers[cap_oscillationControl.ID] = {
    setFanOscillationMode = cmds.set_oscillation_mode,
  }
end
if cap_powerOffTimer then
  capability_handlers[cap_powerOffTimer.ID] = {
    ["setTimer"] = cmds.set_power_off_timer,
  }
end
if cap_dryAfterOff then
  capability_handlers[cap_dryAfterOff.ID] = {
    setDryAfterOff = cmds.set_dry_after_off,
    enable = cmds.enable_dry_after_off,
    disable = cmds.disable_dry_after_off,
  }
end
if cap_filterMaintenance then
  capability_handlers[cap_filterMaintenance.ID] = {
    ["resetFilter"] = cmds.reset_filter,
  }
end
if cap_favoriteLevel then
  capability_handlers[cap_favoriteLevel.ID] = {
    ["setFavoriteLevel"] = cmds.set_favorite_level,
  }
end

discovery.on_connected = function(driver, device)
  device_init(driver, device)
end

local cap_xiaomiLink = safe_cap("earthpanel38939.xiaomiLocalLink")
if cap_xiaomiLink then
  capability_handlers[cap_xiaomiLink.ID] = {
    enroll = function(driver, device, command)
      require("enrollment").handle(driver, device, command.args, function(message)
        device:set_field("enrollment_status", message, {persist=true})
        device:emit_event(cap_xiaomiLink.status(message))
      end)
    end,
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

-- Hub-owned periodic rediscovery repairs DHCP changes without a host bridge.
if driver.call_on_schedule then
  driver:call_on_schedule(300, function() discovery.scan(driver) end, "xiaomi_local_discovery")
  driver:call_with_delay(5, function() discovery.scan(driver) end, "xiaomi_initial_discovery")
end
log.info("xiaomi-miio driver:run()")
driver:run()
