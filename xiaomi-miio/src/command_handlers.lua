--[[
  Capability command handlers. Each handler looks up the device-specific module
  attached to the device during init and forwards the call.
]]

local log = require "log"
local cosock = require "cosock"
local capabilities = require "st.capabilities"

local M = {}
local command_queues = setmetatable({}, { __mode = "k" })
local command_versions = setmetatable({}, { __mode = "k" })

-- Optimistic UI: emit the expected new state immediately so the SmartThings
-- app reflects the change without waiting on a LAN round-trip. A targeted
-- confirmation shortly afterwards either keeps it or rolls it back.
local function optimistic(device, event)
  if event then device:emit_event(event) end
end

local function get_handler(device)
  return device:get_field("handler_module"), device:get_field("client")
end

local function still_attached(device, handler, client)
  local current_handler, current_client = get_handler(device)
  return current_handler == handler and current_client == client
end

local function command_client(device, handler, client)
  -- Compound setters may issue several RPCs. Finish an RPC already in flight,
  -- but stop its unsent follow-up writes if preferences changed meanwhile.
  return setmetatable({}, { __index = function(_, name)
    local value = client[name]
    if type(value) ~= "function" then return value end
    return function(_, ...)
      if not still_attached(device, handler, client) then return nil, "attachment changed" end
      return value(client, ...)
    end
  end })
end

local function publication_device(device, handler, client, current)
  current = current or function() return still_attached(device, handler, client) end
  local mutations = { emit_event = true, set_field = true, online = true, offline = true }
  -- SDK event publication can yield or invoke lifecycle work. Check every
  -- publication, not just the readback before apply_state starts emitting.
  return setmetatable({}, { __index = function(_, name)
    local value = device[name]
    if type(value) ~= "function" then return value end
    return function(_, ...)
      if mutations[name] and not current() then return nil end
      local result = value(device, ...)
      if name == "get_field" and select(1, ...) == "xiaomi_alert_sink" and type(result) == "function" then
        return function(message)
          if not current() then return false end
          return result(message, current)
        end
      end
      return result
    end
  end })
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
    if not still_attached(device, handler, client) then return nil, "attachment changed" end
    idx = idx + 1
    local chunk = {}
    for j = i, math.min(i + CHUNK_SIZE - 1, #props) do
      chunk[#chunk + 1] = props[j]
    end
    if idx > 1 then cosock.socket.sleep(0.05) end
    local result, err = client:get_properties(chunk, session)
    if result then
      local requested = {}
      for _, prop in ipairs(chunk) do requested[prop.did] = prop end
      for _, p in ipairs(result) do
        local prop = type(p) == "table" and requested[p.did]
        local value_type = type(p) == "table" and type(p.value)
        local valid_value = value_type == "boolean" or value_type == "string"
          or (value_type == "number" and p.value == p.value and math.abs(p.value) < math.huge)
        if prop and tonumber(p.code) == 0 and valid_value
            and (not prop.value_type or value_type == prop.value_type) then
          any_ok = true
          by_did[p.did] = p.value
        else
          last_err = string.format("property %s failed with code %s",
            tostring(type(p) == "table" and p.did or "?"),
            tostring(type(p) == "table" and p.code or "missing"))
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

local function refresh_properties(device, props, action_name, during_command, command_version)
  local queue = command_queues[device]
  if queue and queue.running and not during_command then return true end
  local version = command_version or command_versions[device]
  local handler, client = get_handler(device)
  if not (handler and client) then return false end
  local values, err = read_properties(device, handler, client, props)
  -- A poll started before a command must not overwrite the newer state.
  if command_versions[device] ~= version or not still_attached(device, handler, client) then return true end
  local published = publication_device(device, handler, client, function()
    return command_versions[device] == version and still_attached(device, handler, client)
  end)
  if not values then
    published:offline()
    warn_fail(device, action_name or "refresh", err)
    return false
  end
  published:online()
  handler.apply_state(published, values)
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
  local wanted = {}
  for did in pairs(expected) do
    wanted[did] = true
    for _, related in ipairs((handler.confirmation_dependencies or {})[did] or {}) do
      wanted[related] = true
    end
  end
  for _, prop in ipairs(handler.refresh_props or {}) do
    if wanted[prop.did] then selected[#selected + 1] = prop end
  end
  return selected
end

local function values_match(values, expected, props, tolerances)
  if not values then return false end
  for _, prop in ipairs(props or {}) do
    if values[prop.did] == nil then return false end
  end
  for did, wanted in pairs(expected) do
    local actual = values[did]
    if actual == nil then return false end
    if type(actual) == "number" and type(wanted) == "number" then
      local tolerance = (tolerances or {})[did]
      if tolerance then
        -- Countdown readback may decrease, but must never increase.
        if actual > wanted or wanted - actual > tolerance then return false end
      elseif math.abs(actual - wanted) > 0.001 then return false end
    elseif actual ~= wanted then
      return false
    end
  end
  return true
end

local function confirm_after_command(device, handler, client, action_name, expected, version)
  if not still_attached(device, handler, client) then return false end
  local function current()
    return still_attached(device, handler, client) and (version == nil or command_versions[device] == version)
  end
  local published = publication_device(device, handler, client, current)
  if not expected or next(expected) == nil then
    return refresh_properties(device, handler.core_props or handler.refresh_props,
      action_name .. " confirmation", true, version)
  end

  local props = confirmation_props(handler, expected)
  if #props == 0 then
    warn_fail(device, action_name, "no confirmation properties")
    published:offline()
    return false
  end

  cosock.socket.sleep(0.5)
  if not still_attached(device, handler, client) then return false end
  local first_values, first_err = read_properties(device, handler, client, props)
  if not still_attached(device, handler, client) then return false end
  if values_match(first_values, expected, props, handler.confirmation_tolerances) then
    published:online()
    handler.apply_state(published, first_values)
    return true
  end

  -- Some miIO devices acknowledge a set before the new value is readable.
  -- Retry once at roughly two seconds from the command.
  cosock.socket.sleep(1.5)
  if not still_attached(device, handler, client) then return false end
  local final_values, final_err = read_properties(device, handler, client, props)
  if not still_attached(device, handler, client) then return false end
  if final_values then
    local expected_complete = true
    for did in pairs(expected) do
      if final_values[did] == nil then expected_complete = false end
    end
    if expected_complete then published:online() else published:offline() end
    handler.apply_state(published, final_values)
    if values_match(final_values, expected, props, handler.confirmation_tolerances) then return true end
    warn_fail(device, action_name, expected_complete
      and "confirmation mismatch; applied available device state"
      or "confirmation incomplete; commanded state is unavailable")
    return false
  end

  -- No reliable actual state is available. Keep no optimistic state marked as
  -- trustworthy and let the next core poll recover the device.
  published:offline()
  warn_fail(device, action_name,
    final_err or first_err or "confirmation failed")
  return false
end

-- Apply a setter in the background. Device setters return a third value: a
-- map of raw MiOT did -> expected value used for the targeted confirmation.
local function fire_and_confirm(_, device, action_name, fn, finished)
  local handler, client = get_handler(device)
  if not (handler and client) then return end
  command_versions[device] = (command_versions[device] or 0) + 1
  local queue = command_queues[device]
  if not queue then queue = { items = {} }; command_queues[device] = queue end
  queue.items[#queue.items + 1] = { action = action_name, run = fn, finished = finished,
    version = command_versions[device] }
  if queue.running then return end
  queue.running = true
  cosock.spawn(function()
    while #queue.items > 0 do
      local task = table.remove(queue.items, 1)
      -- Credentials may change while an earlier setter is waiting for a reply.
      -- Only unsent queued commands use the replacement attachment; an already
      -- sent command is never replayed on it.
      local handler, client = get_handler(device)
      local ran, failure = pcall(function()
        if not (handler and client) then return end
        local ok, err, expected = task.run(handler, command_client(device, handler, client))
        if not ok then warn_fail(device, task.action, err) end
        confirm_after_command(device, handler, client, task.action, expected, task.version)
      end)
      if not ran then warn_fail(device, task.action, failure) end
      if task.finished and still_attached(device, handler, client) then
        local done, err = pcall(task.finished, publication_device(device, handler, client))
        if not done then warn_fail(device, task.action, err) end
      end
    end
    queue.running = false
  end, "device_command_queue")
end

local NS = "earthpanel38939"
local function cap(id)
  local ok, c = pcall(function() return capabilities[id] end)
  if ok then return c end
end
local cap_childLock      = cap(NS .. ".childLock")
local cap_alarmBuzzer    = cap(NS .. ".alarmBuzzer")
local cap_indicatorMode  = cap(NS .. ".indicatorLightMode")
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
  local level = tonumber(command.args.level)
  if not level or level < 0 or level > 14 or level ~= math.floor(level) then return end
  if cap_favoriteLevel then
    optimistic(device, cap_favoriteLevel.level(level))
  end
  optimistic(device, capabilities.switch.switch.on())
  optimistic(device, capabilities.mode.mode("즐겨찾기"))
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
  local handler = device:get_field("handler_module")
  local timer_cap = handler and handler.timer_capability and cap(handler.timer_capability) or cap_powerOffTimer
  if timer_cap then
    optimistic(device, timer_cap.minutes({ value = command.args.minutes, unit = "min" }))
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
  -- The device setter checks the current mode before accepting humidity.
  -- Do not briefly display a rejected value in clothes-drying mode.
  fire_and_confirm(driver, device, "set_target_humidity",
    function(h, c) return call_setter(h, c, "set_target_humidity", command.args.humidity) end)
end

function M.set_dry_after_off(driver, device, command)
  fire_and_confirm(driver, device, "set_dry_after_off",
    function(h, c) return call_setter(h, c, "set_dry_after_off", command.args.state) end)
end

function M.enable_dry_after_off(driver, device)
  return M.set_dry_after_off(driver, device, { args = { state = "on" } })
end

function M.disable_dry_after_off(driver, device)
  return M.set_dry_after_off(driver, device, { args = { state = "off" } })
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
    function(h, c) return call_setter(h, c, "reset_filter") end,
    function(completed_device)
      if cap_filterMaintenance and handler and handler.uses_filter_maintenance then
        optimistic(completed_device, cap_filterMaintenance.status("ready"))
      end
    end)
end

return M
