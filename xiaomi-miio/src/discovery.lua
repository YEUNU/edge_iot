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
  if type(saved) == "table" then
    connection.save(device, saved)
    driver.datastore[key] = nil
  end
end

local function valid_did(value)
  return type(value) == "number" and value > 0 and value < 0xFFFFFFFF and value % 1 == 0
end

local function scan_item(driver, devices, item, should_continue)
  if type(item) ~= "table" or not valid_did(item.did) or not connection.valid_ip(item.ip) then return end
  local dni = string.format("xiaomi-miio-%d", item.did)
  local key = "discovered:" .. dni
  local pending = driver.datastore and driver.datastore[key]
  if type(pending) ~= "table" or (pending.did and pending.did ~= item.did) then pending = nil end
  local existing, tokens, seen = nil, {}, {}
  local function candidate(token)
    if connection.valid_token(token) and not seen[token:lower()] then
      seen[token:lower()] = true
      tokens[#tokens + 1] = token
    end
  end
  local fallback
  for _, device in ipairs(devices) do
    if device.get_field then
      local saved = device:get_field("local_connection") or {}
      local did = saved.did or tonumber((device.device_network_id or ""):match("^xiaomi%-miio%-(%d+)$"))
      if did == item.did then existing = device; break end
      if not did and connection.get(device).deviceIp == item.ip then fallback = fallback or device end
    end
  end
  existing = existing or fallback
  -- A scan can yield during authentication while enrollment or preferences
  -- replace this connection. Never commit an answer based on older credentials.
  local original_connection = existing and existing:get_field("local_connection")
  local original_preferences = existing and connection.get(existing)
  local original_pending = driver.datastore and driver.datastore[key]
  if existing then candidate(connection.get(existing).deviceToken) end
  if pending then candidate(pending.token) end
  candidate(item.token)
  local info, token
  for _, value in ipairs(tokens) do
    if not should_continue() then return end
    local client = assert(Client.new{ip = item.ip, token = value, timeout_s = 1})
    local session = client:begin_session()
    -- The encrypted reply must belong to the same DID as this discovery record.
    local result = session and session.dev_id == item.did and client:miio_info(session) or nil
    if type(result) == "table" and models[result.model]
      and (not existing or existing.model == result.model or existing.model == "xiaomi.setup")
      and (not pending or not pending.model or pending.model == result.model) then
      info, token = result, value
      break
    end
  end
  if not info then
    log.info("local discovery authentication unavailable for device " .. tostring(item.did))
    return
  end
  if not should_continue() then return end
  if driver.datastore and driver.datastore[key] ~= original_pending then return end
  if existing then
    local current = connection.get(existing)
    if existing:get_field("local_connection") ~= original_connection
        or current.deviceIp ~= original_preferences.deviceIp
        or current.deviceToken ~= original_preferences.deviceToken then return end
  end
  local record = {ip = item.ip, token = token, did = item.did, model = info.model}
  if existing then
    local previous = existing:get_field("local_connection") or {}
    record.preference_token = previous.preference_token
    local changed = previous.ip ~= record.ip or previous.did ~= record.did or previous.token ~= record.token or previous.model ~= record.model
    if changed then
      connection.save(existing, record)
      existing:set_field("xiaomi_attach_pending", true)
    end
    if (changed or existing:get_field("xiaomi_attach_pending")) and Discovery.on_connected then
      local attached = pcall(Discovery.on_connected, driver, existing)
      if attached then existing:set_field("xiaomi_attach_pending", nil) end
    end
    log.info("local discovery authenticated existing device " .. tostring(item.did))
  elseif driver.datastore then
    -- Device creation is asynchronous. The pending token also authenticates
    -- modern devices whose Hello reply deliberately hides their credentials.
    local requested_at = pending and tonumber(pending.created_at) or 0
    local recently_requested = requested_at and requested_at == requested_at and requested_at > 0
      and requested_at <= os.time() and os.time() - requested_at < 120
    record.created_at = recently_requested and requested_at or os.time()
    driver.datastore[key] = record -- Refresh authenticated credentials even while creation is pending.
    if not recently_requested then
      local model = models[info.model]
      local ok, created = pcall(driver.try_create_device, driver, {type = "LAN", device_network_id = dni,
        label = model.label, profile = model.profile, manufacturer = "Xiaomi",
        model = model.model, vendor_provided_label = model.vendor_label})
      if not ok or not created then
        record.created_at = 0
        driver.datastore[key] = record
      end
    end
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
  for key, record in pairs(driver.datastore or {}) do
    if type(key) == "string" and key:match("^discovered:") and type(record) == "table"
      and connection.valid_ip(record.ip) then addresses[#addresses + 1] = record.ip end
  end
  local found, err = network.scan(addresses, should_continue)
  if err then log.warn("local discovery unavailable: " .. tostring(err)); return end
  if type(found) ~= "table" then return end
  for _, item in ipairs(found) do
    if not should_continue() then return end
    local ok = pcall(scan_item, driver, devices, item, should_continue)
    if not ok then log.warn("local discovery device processing failed; continuing scan") end
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
  should_continue = should_continue or function() return true end
  Discovery.scan(driver, should_continue)
  -- Never create a second unconfigured setup record.
  for _, dev in ipairs(driver:get_devices()) do
    if dev.model == "xiaomi.setup" then
      log.info("discovery: Xiaomi setup device already exists")
      return
    end
  end

  if not should_continue() then return end
  local now = os.time()
  local requested_at = driver.datastore and driver.datastore.xiaomi_setup_create_at or driver.xiaomi_setup_create_at
  if type(requested_at) == "number" and requested_at > 0 and requested_at <= now and now - requested_at < 120 then return end
  driver.xiaomi_setup_create_at = now
  if driver.datastore then driver.datastore.xiaomi_setup_create_at = now end
  local create_msg = {
    type = "LAN",
    device_network_id = random_dni("xiaomi-setup"),
    label = "Xiaomi 기기 설정",
    profile = "xiaomi-setup.v1",
    manufacturer = "Xiaomi",
    model = "xiaomi.setup",
    vendor_provided_label = "Xiaomi 기기 설정",
  }
  local ran, ok = pcall(driver.try_create_device, driver, create_msg)
  if ran and ok then
    log.info("discovery: created Xiaomi setup device")
  else
    driver.xiaomi_setup_create_at = nil
    if driver.datastore then driver.datastore.xiaomi_setup_create_at = nil end
    log.error("discovery: try_create_device failed")
  end
end

return Discovery
