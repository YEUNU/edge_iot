local log = require "log"

local Discovery = {}

local function hex_byte() return string.format("%02x", math.random(0, 255)) end
local function random_dni()
  local parts = {}
  for i = 1, 6 do parts[i] = hex_byte() end
  return "tuyair-" .. table.concat(parts)
end

function Discovery.handle(driver, _, should_continue)
  local existing = {}
  for _, dev in ipairs(driver:get_devices()) do
    existing[dev.device_network_id] = true
  end
  if should_continue() then
    local already = false
    for _, dev in ipairs(driver:get_devices()) do
      if dev.model == "tuya.ir.ac" then already = true; break end
    end
    if not already then
      local dni = random_dni()
      local ok, err = driver:try_create_device{
        type = "LAN",
        device_network_id = dni,
        label = "Tuya IR Air Conditioner",
        profile = "tuya-ir-ac.v1",
        manufacturer = "Tuya",
        model = "tuya.ir.ac",
        vendor_provided_label = "Tuya IR AC (Cloud)",
      }
      if ok then
        log.info("discovery: created placeholder Tuya IR AC " .. dni)
      else
        log.error("discovery: try_create_device failed: " .. tostring(err))
      end
    end
  end
end

return Discovery
