-- Read-only test of the actual discovery code against a physical appliance.
-- A fresh driver facade has no devices, preferences, datastore or tokens.
-- No SmartThings devices are created/deleted. The IP is only a probe target.
-- Usage: lua tests/miio_fresh_enrollment.lua . <device-ip>
local root, target = ...
assert(root and target, "specify repository and device IP")
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local connection = require "connection"
assert(connection.valid_ip(target), "invalid target")
package.preload.log = function()
  return {info=print, warn=print, error=print}
end
local network = require "miio.discover"
local flow = require "discovery"
local candidates = {}
-- First run actual broadcast discovery with no remembered addresses.
for _, item in ipairs(network.scan({})) do
  if item.ip == target then candidates[#candidates + 1] = item end
end
print("broadcast_found=" .. tostring(#candidates > 0))
-- Also probe its IP to distinguish a broadcast limitation from missing key.
local replies = network.scan({target})
local target_replies = {}
for _, item in ipairs(replies) do
  if item.ip == target then
    target_replies[#target_replies+1] = item
    print("physical_reply did=" .. item.did .. " token_candidate=" .. tostring(item.token ~= nil))
  end
end
assert(#target_replies > 0, "device did not respond; enrollment result inconclusive")
network.scan = function(addresses)
  assert(#addresses == 0, "fresh driver unexpectedly had remembered addresses")
  return target_replies
end
local creates = {}
local driver = {datastore={}}
function driver:get_devices() return {} end
function driver:try_create_device(metadata)
  creates[#creates+1] = metadata
  return true
end
flow.scan(driver)
print("fresh_authenticated_registration_requests=" .. #creates)
print("fresh_credentials_saved=" .. tostring(next(driver.datastore) ~= nil))
for _, metadata in ipairs(creates) do print("authenticated_model=" .. metadata.model) end
print("TEST_SCOPE=physical LAN replies + production discovery with empty driver state; no actual SmartThings deletion")
