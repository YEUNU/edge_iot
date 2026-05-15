--[[
  Tuya AC command handlers. Optimistic UI emit + background cloud RPC + refresh.
]]

local log = require "log"
local cosock = require "cosock"
local capabilities = require "st.capabilities"
local ac = require "tuya.ac"

local M = {}

local function get_client(device) return device:get_field("client") end

local function warn_fail(device, action, err)
  log.warn(string.format("[%s] %s failed: %s", device.label, action, tostring(err)))
end

function M.refresh(driver, device)
  local client = get_client(device)
  local device_id = device:get_field("tuya_device_id")
  if not (client and device_id) then return end
  local result, err = client:get_status(device_id)
  if not result then
    device:offline()
    warn_fail(device, "refresh", err)
    return
  end
  device:online()
  local s = ac.parse_status(result)
  if s.power ~= nil then
    device:emit_event(s.power and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end
  if s.mode and ac.TUYA_TO_ST_MODE[s.mode] then
    device:emit_event(capabilities.airConditionerMode.airConditionerMode(ac.TUYA_TO_ST_MODE[s.mode]))
  end
  if s.wind and ac.TUYA_TO_ST_FAN[s.wind] then
    device:emit_event(capabilities.airConditionerFanMode.fanMode(ac.TUYA_TO_ST_FAN[s.wind]))
  end
  if s.temp then
    device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = s.temp, unit = "C" }))
  end
end

local function send_async(driver, device, action_name, commands)
  local client = get_client(device)
  local device_id = device:get_field("tuya_device_id")
  if not (client and device_id) then return end
  cosock.spawn(function()
    local _, err = client:send_commands(device_id, commands)
    if err then warn_fail(device, action_name, err) end
    M.refresh(driver, device)
  end, "tuya_" .. action_name)
end

function M.switch_on(driver, device)
  device:emit_event(capabilities.switch.switch.on())
  send_async(driver, device, "switch_on", { { code = "switch", value = true } })
end

function M.switch_off(driver, device)
  device:emit_event(capabilities.switch.switch.off())
  send_async(driver, device, "switch_off", { { code = "switch", value = false } })
end

function M.set_ac_mode(driver, device, command)
  local st_mode = command.args.mode
  local tuya = ac.ST_TO_TUYA_MODE[st_mode]
  if not tuya then warn_fail(device, "set_ac_mode", "unknown st mode " .. tostring(st_mode)); return end
  device:emit_event(capabilities.airConditionerMode.airConditionerMode(st_mode))
  send_async(driver, device, "set_ac_mode", { { code = "mode", value = tuya } })
end

function M.set_fan_mode(driver, device, command)
  local st_fan = command.args.fanMode
  local tuya = ac.ST_TO_TUYA_FAN[st_fan]
  if not tuya then warn_fail(device, "set_fan_mode", "unknown fan mode " .. tostring(st_fan)); return end
  device:emit_event(capabilities.airConditionerFanMode.fanMode(st_fan))
  send_async(driver, device, "set_fan_mode", { { code = "fan", value = tuya } })
end

function M.set_cooling_setpoint(driver, device, command)
  local sp = command.args.setpoint
  if type(sp) == "table" then sp = sp.value end
  sp = math.max(16, math.min(30, math.floor(tonumber(sp) or 24)))
  device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = sp, unit = "C" }))
  send_async(driver, device, "set_cooling_setpoint", { { code = "temp", value = sp } })
end

return M
