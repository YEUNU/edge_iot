--[[
  Capability command handlers. Each handler looks up the device-specific module
  attached to the device during init and forwards the call.
]]

local log = require "log"
local cosock = require "cosock"
local capabilities = require "st.capabilities"

local M = {}

-- Optimistic UI: emit the expected new state immediately so the SmartThings
-- app reflects the change without waiting on a full refresh round-trip.
-- The next 10s poll will overwrite with the device's actual reading.
local function optimistic(device, event)
  if event then device:emit_event(event) end
end

local function schedule_refresh(driver, device)
  cosock.spawn(function() M.refresh(driver, device) end, "post_set_refresh")
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

function M.refresh(driver, device)
  local handler, client = get_handler(device)
  if not (handler and client) then return end

  local by_did = {}
  local any_ok = false
  local last_err
  local idx = 0
  local CHUNK_SIZE = handler.chunk_size or DEFAULT_CHUNK_SIZE
  for i = 1, #handler.refresh_props, CHUNK_SIZE do
    idx = idx + 1
    local chunk = {}
    for j = i, math.min(i + CHUNK_SIZE - 1, #handler.refresh_props) do
      chunk[#chunk + 1] = handler.refresh_props[j]
    end
    if idx > 1 then cosock.socket.sleep(0.3) end
    local result, err = client:get_properties(chunk)
    if result then
      any_ok = true
      for _, p in ipairs(result) do
        if p.code == 0 then by_did[p.did] = p.value end
      end
    else
      last_err = err
      log.warn(string.format("[%s] refresh chunk %d failed: %s", device.label, idx, tostring(err)))
    end
  end

  if not any_ok then
    device:offline()
    warn_fail(device, "refresh", last_err or "no chunks succeeded")
    return
  end
  device:online()
  handler.apply_state(device, by_did)
end

-- Apply a setter on the device in the background, then trigger a refresh
-- so the next poll-cycle value catches up. The caller is expected to have
-- already done an optimistic emit of the expected post-state.
local function fire_and_refresh(driver, device, action_name, fn)
  local handler, client = get_handler(device)
  if not handler then return end
  cosock.spawn(function()
    local ok, err = fn(handler, client)
    if not ok then warn_fail(device, action_name, err) end
    M.refresh(driver, device)
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

function M.switch_on(driver, device)
  optimistic(device, capabilities.switch.switch.on())
  fire_and_refresh(driver, device, "switch_on",
    function(h, c) return h.set_switch(c, true) end)
end

function M.switch_off(driver, device)
  optimistic(device, capabilities.switch.switch.off())
  fire_and_refresh(driver, device, "switch_off",
    function(h, c) return h.set_switch(c, false) end)
end

function M.set_fan_speed(driver, device, command)
  optimistic(device, capabilities.fanSpeed.fanSpeed(command.args.speed))
  fire_and_refresh(driver, device, "set_fan_speed",
    function(h, c) return h.set_fan_speed and h.set_fan_speed(c, command.args.speed) end)
end

function M.set_fan_speed_percent(driver, device, command)
  optimistic(device, capabilities.fanSpeedPercent.percent(command.args.percent))
  fire_and_refresh(driver, device, "set_fan_speed_percent",
    function(h, c) return h.set_fan_speed_percent and h.set_fan_speed_percent(c, command.args.percent) end)
end

function M.set_mode(driver, device, command)
  optimistic(device, capabilities.mode.mode(command.args.mode))
  fire_and_refresh(driver, device, "set_mode",
    function(h, c) return h.set_mode and h.set_mode(c, command.args.mode) end)
end

function M.set_oscillation_mode(driver, device, command)
  optimistic(device, capabilities.fanOscillationMode.fanOscillationMode(command.args.fanOscillationMode))
  fire_and_refresh(driver, device, "set_oscillation_mode",
    function(h, c) return h.set_oscillation_mode and h.set_oscillation_mode(c, command.args.fanOscillationMode) end)
end

function M.set_switch_level(driver, device, command)
  optimistic(device, capabilities.switchLevel.level(command.args.level))
  fire_and_refresh(driver, device, "set_switch_level",
    function(h, c) return h.set_switch_level and h.set_switch_level(c, command.args.level) end)
end

function M.set_target_humidity(driver, device, command)
  if cap_targetHumidity then
    optimistic(device, cap_targetHumidity.targetHumidity({ value = command.args.humidity, unit = "%" }))
  end
  fire_and_refresh(driver, device, "set_target_humidity",
    function(h, c) return h.set_target_humidity and h.set_target_humidity(c, command.args.humidity) end)
end

local function emit_lock(device, state)
  if cap_childLock then optimistic(device, cap_childLock.lock(state)) end
end
function M.set_child_lock(driver, device, command)
  emit_lock(device, command.args.state)
  fire_and_refresh(driver, device, "set_child_lock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, command.args.state) end)
end
function M.child_lock(driver, device)
  emit_lock(device, "locked")
  fire_and_refresh(driver, device, "lock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, "locked") end)
end
function M.child_unlock(driver, device)
  emit_lock(device, "unlocked")
  fire_and_refresh(driver, device, "unlock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, "unlocked") end)
end

local function emit_buzzer(device, state)
  if cap_alarmBuzzer then optimistic(device, cap_alarmBuzzer.buzzer(state)) end
end
function M.set_alarm_buzzer(driver, device, command)
  emit_buzzer(device, command.args.state)
  fire_and_refresh(driver, device, "set_alarm_buzzer",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, command.args.state) end)
end
function M.buzzer_on(driver, device)
  emit_buzzer(device, "on")
  fire_and_refresh(driver, device, "buzzer_on",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, "on") end)
end
function M.buzzer_off(driver, device)
  emit_buzzer(device, "off")
  fire_and_refresh(driver, device, "buzzer_off",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, "off") end)
end

function M.set_indicator(driver, device, command)
  if cap_indicatorMode then
    optimistic(device, cap_indicatorMode.indicator(command.args.mode))
  end
  fire_and_refresh(driver, device, "set_indicator",
    function(h, c) return h.set_indicator and h.set_indicator(c, command.args.mode) end)
end

return M
