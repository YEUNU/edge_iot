--[[
  Discover and authenticate miIO devices locally. Keep a manual setup fallback
  for devices that do not expose tokens. Credentials never appear in logs.
]]

local log = require "log"
local Discovery = {}
local network = require "miio.discover"
local Client = require "miio.client"
local connection = require "connection"
local models = {}
for _, model in ipairs(require "models") do models[model.model] = model end

function Discovery.restore(driver, device)
  local key = "discovered:" .. device.device_network_id
  local saved = driver.datastore and driver.datastore[key]
  if saved then
    connection.save(device, saved)
    driver.datastore[key] = nil
  end
end

local function scan(driver, should_continue)
  local devices, addresses = driver:get_devices(), {}
  for _, device in ipairs(devices) do
    if device.get_field then
      local prefs = connection.get(device)
      if connection.valid_ip(prefs.deviceIp) then addresses[#addresses + 1] = prefs.deviceIp end
    end
  end
  local found, err = network.scan(addresses, should_continue)
  if err then log.warn("local discovery unavailable: " .. tostring(err)); return end
  for _, item in ipairs(found) do
    if not should_continue() then return end
    local existing, token
    for _, device in ipairs(devices) do
      if device.get_field then
        local saved = device:get_field("local_connection") or {}
        local prefs = connection.get(device)
        if saved.did == item.did or (not saved.did and prefs.deviceIp == item.ip) then
          existing, token = device, prefs.deviceToken
          break
        end
      end
    end
    if not connection.valid_token(token) then token = item.token end
    if connection.valid_token(token) then
      local client = Client.new{ip = item.ip, token = token, timeout_s = 1}
      local info = client:miio_info()
      -- A hello is unauthenticated. Only a valid encrypted model response
      -- permits persistence, IP migration or creation.
      if type(info) == "table" and models[info.model]
        and (not existing or existing.model == info.model or existing.model == "xiaomi.setup") then
        local record = {ip = item.ip, token = token, did = item.did, model = info.model}
        if existing then
          local previous = existing:get_field("local_connection") or {}
          record.preference_token = previous.preference_token
          if previous.ip ~= record.ip or previous.did ~= record.did or previous.token ~= record.token or previous.model ~= record.model then
            connection.save(existing, record)
            if Discovery.on_connected then Discovery.on_connected(driver, existing) end
          end
          log.info("local discovery authenticated existing device " .. tostring(item.did))
        elseif driver.datastore then
          local dni = "xiaomi-miio-" .. tostring(item.did)
          local duplicate = false
          for _, device in ipairs(devices) do
            if device.device_network_id == dni then duplicate = true end
          end
          local key = "discovered:" .. dni
          local pending = driver.datastore[key]
          -- Device creation is asynchronous. Retry a lost request after two
          -- minutes instead of leaving its credentials permanently stranded.
          if not duplicate and (not pending or os.time() - (pending.created_at or 0) >= 120) then
            record.created_at = os.time()
            driver.datastore[key] = record
            local model = models[info.model]
            local created = driver:try_create_device({type = "LAN", device_network_id = dni,
              label = model.label, profile = model.profile, manufacturer = "Xiaomi",
              model = model.model, vendor_provided_label = model.vendor_label})
            if not created then driver.datastore[key] = nil end
          end
        end
      else
        log.info("local discovery authentication failed for device " .. tostring(item.did))
      end
    else
      log.info("local discovery found device " .. tostring(item.did) .. "; token not supplied by device")
    end
  end
end

function Discovery.scan(driver, should_continue)
  if driver.xiaomi_scan_running or driver.xiaomi_enrolling then return end
  driver.xiaomi_scan_running = true
  local ok, err = pcall(scan, driver, should_continue or function() return true end)
  driver.xiaomi_scan_running = false
  if not ok then log.warn("local discovery failed: " .. tostring(err)) end
end

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
  Discovery.scan(driver, should_continue)
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
