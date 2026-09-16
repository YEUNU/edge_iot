--[[
  Capability command handlers. Each handler looks up the device-specific module
  attached to the device during init and forwards the call.
]]

local log = require "log"
local cosock = require "cosock"
local capabilities = require "st.capabilities"

local M = {}

-- Optimistic UI: emit the expected new state immediately so the SmartThings
-- app reflects the change without waiting on a LAN round-trip. A targeted
-- confirmation shortly afterwards either keeps it or rolls it back.
local function optimistic(device, event)
  if event then device:emit_event(event) end
end

local function get_handler(device)
  return device:get_field("handler_module"), device:get_field("client")
end

local function warn_fail(device, action, err)
  log.warn(string.format("[%s] %s failed: %s", device.label, action, tostring(err)))
end

-- Split props into chunks of at most CHUNK_SIZE so devices that fail on
-- large get_properties batches (e.g. zhimi.airp.cpa4 → -9999 user ack timeout)
-- still produce useful state. Handlers may override via handler.chunk_size.
local DEFAULT_CHUNK_SIZE = 4

local function read_properties(device, handler, client, props)
  props = props or handler.refresh_props or {}
  if not (handler and client) then return nil, "device is not attached" end

  -- One handshake covers every chunk in this refresh cycle.
  local session, sess_err = client:begin_session()
  if not session then
    return nil, "handshake: " .. tostring(sess_err)
  end

  local by_did = {}
  local any_ok = false
  local last_err
  local idx = 0
  local CHUNK_SIZE = handler.chunk_size or DEFAULT_CHUNK_SIZE
  for i = 1, #props, CHUNK_SIZE do
    idx = idx + 1
    local chunk = {}
    for j = i, math.min(i + CHUNK_SIZE - 1, #props) do
      chunk[#chunk + 1] = props[j]
    end
    if idx > 1 then cosock.socket.sleep(0.05) end
    local result, err = client:get_properties(chunk, session)
    if result then
      for _, p in ipairs(result) do
        if tonumber(p.code) == 0 then
          any_ok = true
          by_did[p.did] = p.value
        else
          last_err = string.format("property %s failed with code %s",
            tostring(p.did or "?"), tostring(p.code or "missing"))
          log.warn(string.format("[%s] refresh chunk %d: %s",
            device.label, idx, last_err))
        end
      end
    else
      last_err = err
      log.warn(string.format("[%s] refresh chunk %d failed: %s", device.label, idx, tostring(err)))
    end
  end

  if not any_ok then
    return nil, last_err or "no properties succeeded"
  end
  return by_did
end

local function refresh_properties(device, props, action_name)
  local handler, client = get_handler(device)
  if not (handler and client) then return false end
  local values, err = read_properties(device, handler, client, props)
  if not values then
    device:offline()
    warn_fail(device, action_name or "refresh", err)
    return false
  end
  device:online()
  handler.apply_state(device, values)
  return true
end

function M.refresh(_, device)
  local handler = device:get_field("handler_module")
  return handler and refresh_properties(device, handler.refresh_props, "refresh")
end

function M.refresh_core(_, device)
  local handler = device:get_field("handler_module")
  return handler and refresh_properties(device,
    handler.core_props or handler.refresh_props, "core refresh")
end

function M.refresh_aux(_, device)
  local handler = device:get_field("handler_module")
  if not handler or not handler.aux_props or #handler.aux_props == 0 then return true end
  return refresh_properties(device, handler.aux_props, "aux refresh")
end

local function confirmation_props(handler, expected)
  local selected = {}
  for _, prop in ipairs(handler.refresh_props or {}) do
    if expected[prop.did] ~= nil then selected[#selected + 1] = prop end
  end
  return selected
end

local function values_match(values, expected)
  if not values then return false end
  for did, wanted in pairs(expected) do
    local actual = values[did]
    if actual == nil then return false end
    if type(actual) == "number" and type(wanted) == "number" then
      if math.abs(actual - wanted) > 0.001 then return false end
    elseif actual ~= wanted then
      return false
    end
  end
  return true
end

local function confirm_after_command(device, handler, client, action_name, expected)
  if not expected or next(expected) == nil then
    return refresh_properties(device, handler.core_props or handler.refresh_props,
      action_name .. " confirmation")
  end

  local props = confirmation_props(handler, expected)
  if #props == 0 then
    warn_fail(device, action_name, "no confirmation properties")
    device:offline()
    return false
  end

  cosock.socket.sleep(0.5)
  local first_values, first_err = read_properties(device, handler, client, props)
  if values_match(first_values, expected) then
    device:online()
    handler.apply_state(device, first_values)
    return true
  end

  -- Some miIO devices acknowledge a set before the new value is readable.
  -- Retry once at roughly two seconds from the command.
  cosock.socket.sleep(1.5)
  local final_values, final_err = read_properties(device, handler, client, props)
  if final_values then
    device:online()
    handler.apply_state(device, final_values)
    if values_match(final_values, expected) then return true end
    warn_fail(device, action_name, "confirmation mismatch; rolled back to device state")
    return false
  end

  -- No reliable actual state is available. Keep no optimistic state marked as
  -- trustworthy and let the next core poll recover the device.
  device:offline()
  warn_fail(device, action_name,
    final_err or first_err or "confirmation failed")
  return false
end

-- Apply a setter in the background. Device setters return a third value: a
-- map of raw MiOT did -> expected value used for the targeted confirmation.
local function fire_and_confirm(_, device, action_name, fn)
  local handler, client = get_handler(device)
  if not (handler and client) then return end
  cosock.spawn(function()
    local ok, err, expected = fn(handler, client)
    if not ok then warn_fail(device, action_name, err) end
    confirm_after_command(device, handler, client, action_name, expected)
  end, "set_" .. action_name)
end

local NS = "earthpanel38939"
local function cap(id)
  local ok, c = pcall(function() return capabilities[id] end)
  if ok then return c end
end
local cap_childLock      = cap(NS .. ".childLock")
local cap_alarmBuzzer    = cap(NS .. ".alarmBuzzer")
local cap_indicatorMode  = cap(NS .. ".indicatorLightMode")
local cap_targetHumidity = cap(NS .. ".targetHumidity")
local cap_oscillationAngle = cap(NS .. ".fanOscillationDegrees")
local cap_oscillationControl = cap(NS .. ".fanOscillationControl")
local cap_powerOffTimer = cap(NS .. ".powerOffTimer")
local cap_filterMaintenance = cap(NS .. ".filterMaintenance")
local cap_favoriteLevel = cap(NS .. ".airPurifierFavoriteLevel")

local function call_setter(handler, client, name, ...)
  local setter = handler[name]
  if not setter then return nil, name .. " is not supported" end
  return setter(client, ...)
end

function M.switch_on(driver, device)
  optimistic(device, capabilities.switch.switch.on())
  fire_and_confirm(driver, device, "switch_on",
    function(h, c) return h.set_switch(c, true) end)
end

function M.switch_off(driver, device)
  optimistic(device, capabilities.switch.switch.off())
  local handler = device:get_field("handler_module")
  if handler and handler.is_fan then
    optimistic(device, capabilities.fanSpeedPercent.percent(0))
  end
  fire_and_confirm(driver, device, "switch_off",
    function(h, c) return h.set_switch(c, false) end)
end

function M.set_fan_speed(driver, device, command)
  local speed = tonumber(command.args.speed) or 0
  optimistic(device, capabilities.fanSpeed.fanSpeed(speed))
  optimistic(device, speed > 0 and capabilities.switch.switch.on()
    or capabilities.switch.switch.off())
  fire_and_confirm(driver, device, "set_fan_speed",
    function(h, c) return call_setter(h, c, "set_fan_speed", command.args.speed) end)
end

function M.set_favorite_level(driver, device, command)
  local level = tonumber(command.args.level) or 0
  if cap_favoriteLevel then
    optimistic(device, cap_favoriteLevel.level(level))
  end
  optimistic(device, level > 0 and capabilities.switch.switch.on()
    or capabilities.switch.switch.off())
  if level > 0 then optimistic(device, capabilities.mode.mode("즐겨찾기")) end
  fire_and_confirm(driver, device, "set_favorite_level",
    function(h, c) return call_setter(h, c, "set_favorite_level", command.args.level) end)
end

function M.set_fan_speed_percent(driver, device, command)
  local percent = tonumber(command.args.percent) or 0
  optimistic(device, capabilities.fanSpeedPercent.percent(percent))
  optimistic(device, percent > 0 and capabilities.switch.switch.on()
    or capabilities.switch.switch.off())
  fire_and_confirm(driver, device, "set_fan_speed_percent",
    function(h, c) return call_setter(h, c, "set_fan_speed_percent", command.args.percent) end)
end

function M.set_mode(driver, device, command)
  optimistic(device, capabilities.mode.mode(command.args.mode))
  fire_and_confirm(driver, device, "set_mode",
    function(h, c) return call_setter(h, c, "set_mode", command.args.mode) end)
end

function M.set_oscillation_mode(driver, device, command)
  optimistic(device, capabilities.fanOscillationMode.fanOscillationMode(command.args.fanOscillationMode))
  if cap_oscillationControl then
    require("devices.events").emit(device, cap_oscillationControl,
      cap_oscillationControl.fanOscillationMode(command.args.fanOscillationMode))
  end
  fire_and_confirm(driver, device, "set_oscillation_mode",
    function(h, c) return call_setter(h, c, "set_oscillation_mode", command.args.fanOscillationMode) end)
end

function M.set_oscillation_angle(driver, device, command)
  if cap_oscillationAngle then
    optimistic(device, cap_oscillationAngle.degrees(command.args.degrees))
  end
  fire_and_confirm(driver, device, "set_oscillation_angle",
    function(h, c) return call_setter(h, c, "set_oscillation_angle", command.args.degrees) end)
end

function M.set_power_off_timer(driver, device, command)
  if cap_powerOffTimer then
    optimistic(device, cap_powerOffTimer.minutes({ value = command.args.minutes, unit = "min" }))
  end
  fire_and_confirm(driver, device, "set_power_off_timer",
    function(h, c) return call_setter(h, c, "set_power_off_timer", command.args.minutes) end)
end

function M.set_switch_level(driver, device, command)
  optimistic(device, capabilities.switchLevel.level(command.args.level))
  fire_and_confirm(driver, device, "set_switch_level",
    function(h, c) return call_setter(h, c, "set_switch_level", command.args.level) end)
end

function M.set_target_humidity(driver, device, command)
  if cap_targetHumidity then
    optimistic(device, cap_targetHumidity.targetHumidity({ value = command.args.humidity, unit = "%" }))
  end
  fire_and_confirm(driver, device, "set_target_humidity",
    function(h, c) return call_setter(h, c, "set_target_humidity", command.args.humidity) end)
end

local function emit_lock(device, state)
  if cap_childLock then optimistic(device, cap_childLock.lock(state)) end
end
function M.set_child_lock(driver, device, command)
  emit_lock(device, command.args.state)
  fire_and_confirm(driver, device, "set_child_lock",
    function(h, c) return call_setter(h, c, "set_child_lock", command.args.state) end)
end
function M.child_lock(driver, device)
  emit_lock(device, "locked")
  fire_and_confirm(driver, device, "lock",
    function(h, c) return call_setter(h, c, "set_child_lock", "locked") end)
end
function M.child_unlock(driver, device)
  emit_lock(device, "unlocked")
  fire_and_confirm(driver, device, "unlock",
    function(h, c) return call_setter(h, c, "set_child_lock", "unlocked") end)
end

local function emit_buzzer(device, state)
  if cap_alarmBuzzer then optimistic(device, cap_alarmBuzzer.buzzer(state)) end
end
function M.set_alarm_buzzer(driver, device, command)
  emit_buzzer(device, command.args.state)
  fire_and_confirm(driver, device, "set_alarm_buzzer",
    function(h, c) return call_setter(h, c, "set_alarm_buzzer", command.args.state) end)
end
function M.buzzer_on(driver, device)
  emit_buzzer(device, "on")
  fire_and_confirm(driver, device, "buzzer_on",
    function(h, c) return call_setter(h, c, "set_alarm_buzzer", "on") end)
end
function M.buzzer_off(driver, device)
  emit_buzzer(device, "off")
  fire_and_confirm(driver, device, "buzzer_off",
    function(h, c) return call_setter(h, c, "set_alarm_buzzer", "off") end)
end

function M.set_indicator(driver, device, command)
  if cap_indicatorMode then
    optimistic(device, cap_indicatorMode.indicator(command.args.mode))
  end
  fire_and_confirm(driver, device, "set_indicator",
    function(h, c) return call_setter(h, c, "set_indicator", command.args.mode) end)
end

function M.reset_filter(driver, device)
  local handler = device:get_field("handler_module")
  if cap_filterMaintenance and handler and handler.uses_filter_maintenance then
    optimistic(device, cap_filterMaintenance.status("resetting"))
  end
  fire_and_confirm(driver, device, "reset_filter",
    function(h, c) return call_setter(h, c, "reset_filter") end)
end

return M
