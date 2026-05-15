--[[
  Discovery: enumerate the hard-coded device list and try to create a SmartThings
  device record for each one. Verification is best-effort — we send a miIO Hello
  to confirm the device is reachable before adding it; if the Hello fails we skip
  it (the user can rerun discovery once the device is online).
]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local devices_config = require "devices_config"
local Client = require "miio.client"
local handlers = {
  fan_za5  = require "devices.fan_za5",
  airp_cpa4 = require "devices.airp_cpa4",
  derh_13l = require "devices.derh_13l",
}

local Discovery = {}

local function probe(entry)
  local c = Client.new{ ip = entry.ip, token = entry.token, timeout_s = 4 }
  local id, _, err = c:handshake()
  if not id then
    log.warn(string.format("discovery: %s @ %s unreachable: %s",
      entry.model, entry.ip, tostring(err)))
    return false
  end
  log.info(string.format("discovery: %s @ %s id=0x%08x ok",
    entry.model, entry.ip, id))
  return true
end

function Discovery.handle(driver, _, should_continue)
  local known = {}
  for _, dev in ipairs(driver:get_devices()) do
    known[dev.device_network_id] = true
  end

  while should_continue() do
    for _, entry in ipairs(devices_config) do
      if not known[entry.dni] and handlers[entry.handler] then
        if probe(entry) then
          local create_msg = {
            type = "LAN",
            device_network_id = entry.dni,
            label = entry.name,
            profile = entry.profile,
            manufacturer = "Xiaomi",
            model = entry.model,
            vendor_provided_label = entry.vendor_label,
          }
          local ok, err = driver:try_create_device(create_msg)
          if ok then
            known[entry.dni] = true
            log.info("discovery: created " .. entry.dni)
          else
            log.error("discovery: failed to create " .. entry.dni .. ": " .. tostring(err))
          end
        end
      end
    end
    -- Give the user time to confirm in the UI, then re-scan.
    socket.sleep(3)
  end
end

return Discovery
