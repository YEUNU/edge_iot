--[[
  Capability command handlers. Each handler looks up the device-specific module
  attached to the device during init and forwards the call.
]]

local log = require "log"
local cosock = require "cosock"

local M = {}

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

local function with_refresh(driver, device, action_name, fn)
  local handler, client = get_handler(device)
  if not handler then return end
  local ok, err = fn(handler, client)
  if not ok then warn_fail(device, action_name, err) end
  M.refresh(driver, device)
end

function M.switch_on(driver, device)
  with_refresh(driver, device, "switch on",
    function(h, c) return h.set_switch(c, true) end)
end

function M.switch_off(driver, device)
  with_refresh(driver, device, "switch off",
    function(h, c) return h.set_switch(c, false) end)
end

function M.set_fan_speed(driver, device, command)
  with_refresh(driver, device, "set fan speed",
    function(h, c) return h.set_fan_speed and h.set_fan_speed(c, command.args.speed) end)
end

function M.set_fan_speed_percent(driver, device, command)
  with_refresh(driver, device, "set fan speed percent",
    function(h, c) return h.set_fan_speed_percent and h.set_fan_speed_percent(c, command.args.percent) end)
end

function M.set_mode(driver, device, command)
  with_refresh(driver, device, "set mode",
    function(h, c) return h.set_mode and h.set_mode(c, command.args.mode) end)
end

function M.set_oscillation_mode(driver, device, command)
  with_refresh(driver, device, "set oscillation mode",
    function(h, c) return h.set_oscillation_mode and h.set_oscillation_mode(c, command.args.fanOscillationMode) end)
end

function M.set_wind_mode(driver, device, command)
  with_refresh(driver, device, "set wind mode",
    function(h, c) return h.set_wind_mode and h.set_wind_mode(c, command.args.windMode) end)
end

function M.set_switch_level(driver, device, command)
  with_refresh(driver, device, "set switch level",
    function(h, c) return h.set_switch_level and h.set_switch_level(c, command.args.level) end)
end

function M.set_target_humidity(driver, device, command)
  with_refresh(driver, device, "set target humidity",
    function(h, c) return h.set_target_humidity and h.set_target_humidity(c, command.args.humidity) end)
end

function M.set_child_lock(driver, device, command)
  with_refresh(driver, device, "set child lock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, command.args.state) end)
end

function M.child_lock(driver, device)
  with_refresh(driver, device, "lock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, "locked") end)
end

function M.child_unlock(driver, device)
  with_refresh(driver, device, "unlock",
    function(h, c) return h.set_child_lock and h.set_child_lock(c, "unlocked") end)
end

function M.set_alarm_buzzer(driver, device, command)
  with_refresh(driver, device, "set alarm buzzer",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, command.args.state) end)
end

function M.buzzer_on(driver, device)
  with_refresh(driver, device, "buzzer on",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, "on") end)
end

function M.buzzer_off(driver, device)
  with_refresh(driver, device, "buzzer off",
    function(h, c) return h.set_alarm_buzzer and h.set_alarm_buzzer(c, "off") end)
end

function M.set_indicator(driver, device, command)
  with_refresh(driver, device, "set indicator",
    function(h, c) return h.set_indicator and h.set_indicator(c, command.args.mode) end)
end

function M.set_dry_after_off(driver, device, command)
  with_refresh(driver, device, "set dry after off",
    function(h, c) return h.set_dry_after_off and h.set_dry_after_off(c, command.args.state) end)
end

function M.dry_after_off_enable(driver, device)
  with_refresh(driver, device, "dry after off enable",
    function(h, c) return h.set_dry_after_off and h.set_dry_after_off(c, "on") end)
end

function M.dry_after_off_disable(driver, device)
  with_refresh(driver, device, "dry after off disable",
    function(h, c) return h.set_dry_after_off and h.set_dry_after_off(c, "off") end)
end

return M
