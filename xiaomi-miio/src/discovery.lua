--[[
  Discovery: spawn one SmartThings device record per supported Xiaomi model.

  This driver does not know the user's IP/token at build time. We create three
  placeholder devices on first Scan-nearby; the user then enters each device's
  IP and token in its SmartThings settings panel, which triggers
  `infoChanged` and the driver starts polling that device.
]]

local log = require "log"
local models = require "models"

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
  -- Which model handlers already have a device created on this hub?
  local existing = {}
  for _, dev in ipairs(driver:get_devices()) do
    local cfg = dev:get_field("model_def")
    if cfg then existing[cfg.handler] = true end
    -- Also fall back to vendor model name when the field is not yet populated.
    if dev.model then existing[dev.model] = true end
  end

  for _, m in ipairs(models) do
    if not should_continue() then break end
    if not (existing[m.handler] or existing[m.model]) then
      local create_msg = {
        type = "LAN",
        device_network_id = random_dni(m.handler),
        label = m.label,
        profile = m.profile,
        manufacturer = "Xiaomi",
        model = m.model,
        vendor_provided_label = m.vendor_label,
      }
      local ok, err = driver:try_create_device(create_msg)
      if ok then
        log.info("discovery: created placeholder " .. m.label)
        existing[m.handler] = true
      else
        log.error("discovery: try_create_device failed for " .. m.label .. ": " .. tostring(err))
      end
    end
  end
end

return Discovery
