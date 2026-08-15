--[[
  Discovery: create one generic Xiaomi setup record per scan.

  Once the user selects a model and enters its IP/token, init.lua changes the
  same record to the model-specific profile. A later scan can then create the
  next setup record, allowing multiple devices without unused placeholders.
]]

local log = require "log"
local Discovery = {}

local function hex_byte()
  return string.format("%02x", math.random(0, 255))
end

local function random_dni(prefix)
  -- 12-hex pseudo-MAC, suffixed by the model handler key so we never clash
  -- with anything real on the network.
  local parts = {}
  for i = 1, 6 do parts[i] = hex_byte() end
  return prefix .. "-" .. table.concat(parts)
end

function Discovery.handle(driver, _, should_continue)
  -- Never create a second unconfigured setup record.
  for _, dev in ipairs(driver:get_devices()) do
    if dev.model == "xiaomi.setup" then
      log.info("discovery: Xiaomi setup device already exists")
      return
    end
  end

  if not should_continue() then return end
  local create_msg = {
    type = "LAN",
    device_network_id = random_dni("xiaomi-setup"),
    label = "Xiaomi 기기 설정",
    profile = "xiaomi-setup.v1",
    manufacturer = "Xiaomi",
    model = "xiaomi.setup",
    vendor_provided_label = "Xiaomi 기기 설정",
  }
  local ok, err = driver:try_create_device(create_msg)
  if ok then
    log.info("discovery: created Xiaomi setup device")
  else
    log.error("discovery: try_create_device failed: " .. tostring(err))
  end
end

return Discovery
