-- A one-time helper supplies Xiaomi credentials over encrypted LAN packets.
-- After this handler returns, appliance control has no helper/cloud dependency.
local socket = require "cosock.socket"
local json = require "st.json"
local packet = require "miio.packet"
local connection = require "connection"
local Client = require "miio.client"
local discovery = require "discovery"
local models = {}
for _, item in ipairs(require "models") do models[item.model] = item end
local M = {}
local MAX_DEVICES, TRANSFER_TTL_S, ACK_RESERVE_S = 20, 120, 10

local function exchange(address, port, key, path, value, deadline)
  local sock
  local ok, result = pcall(function()
    sock = assert(socket.tcp())
    local function bound_timeout()
      local remaining = deadline and deadline - socket.gettime() or 10
      assert(remaining > 0, "enrollment expired")
      sock:settimeout(math.min(10, remaining))
    end
    bound_timeout()
    assert(sock:connect(address, port))
    local body = packet.build(key, 1, os.time(), json.encode(value))
    local request = "POST " .. path .. " HTTP/1.1\r\nHost: " .. address ..
      "\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
    local offset = 1
    while offset <= #request do
      bound_timeout()
      local sent, _, last = sock:send(request, offset)
      assert(sent or (last and last >= offset), "send failed")
      offset = (sent or last) + 1
    end
    bound_timeout()
    local status = assert(sock:receive("*l"))
    assert(status:match("^HTTP/%d%.%d 200 "), "enrollment rejected")
    local length
    for i = 1, 32 do
      bound_timeout()
      local line = assert(sock:receive("*l"))
      if line == "" then break end
      length = tonumber(line:lower():match("^content%-length:%s*(%d+)$")) or length
      assert(i < 32, "too many headers")
    end
    assert(length and length > 32 and length <= 16384, "invalid size")
    bound_timeout()
    local _, _, plaintext, err = packet.parse(key, assert(sock:receive(length)))
    assert(plaintext and not err, "invalid encrypted reply")
    return assert(json.decode(plaintext))
  end)
  if sock then sock:close() end
  if ok then return result end
  return nil -- Never log credential-bearing response text or parser errors.
end

local function array_size(values)
  if type(values) ~= "table" then return nil end
  local count = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > MAX_DEVICES then return nil end
    count = count + 1
  end
  if count ~= #values then return nil end
  return count
end

local function existing_device(driver, record)
  local fallback
  for _, device in ipairs(driver:get_devices()) do
    local saved = device:get_field("local_connection") or {}
    -- A stored DID or the original network ID takes precedence over a reused IP.
    local did = saved.did or tonumber((device.device_network_id or ""):match("^xiaomi%-miio%-(%d+)$"))
    if did == record.did then return device end
    if not did and (device.model == record.model or device.model == "xiaomi.setup")
      and connection.get(device).deviceIp == record.ip then fallback = fallback or device end
  end
  return fallback
end

local function record_config(record)
  if type(record) ~= "table" then return nil end
  local cfg = models[record.model]
  if cfg and connection.valid_ip(record.ip) and connection.valid_token(record.token)
    and type(record.did) == "number" and record.did > 0 and record.did < 0xFFFFFFFF and record.did % 1 == 0 then return cfg end
end

local function import_record(driver, record, deadline, reconnect)
  local cfg = record_config(record)
  if not cfg or socket.gettime() >= deadline then return "failed" end
  local client = assert(Client.new{ip=record.ip,token=record.token,timeout_s=2,deadline=deadline})
  local session = client:begin_session()
  if not session or session.dev_id ~= record.did or socket.gettime() >= deadline then return "failed" end
  local info = client:miio_info(session)
  if type(info) ~= "table" or info.model ~= record.model or socket.gettime() >= deadline then return "failed" end
  local existing = existing_device(driver, record)
  if existing then
    if existing.model ~= record.model and existing.model ~= "xiaomi.setup" then return "failed" end
    record.preference_token = (existing.preferences or {}).deviceToken
    connection.save(existing, record)
    existing:set_field("xiaomi_attach_pending", true)
    reconnect[#reconnect + 1] = existing
    return "updated"
  end
  local dni = string.format("xiaomi-miio-%d", record.did)
  local pending_key = "discovered:" .. dni
  local pending = driver.datastore[pending_key]
  local recently_requested = type(pending) == "table" and type(pending.created_at) == "number"
    and os.time() - pending.created_at < 120 and pending.created_at > 0 and pending.created_at <= os.time()
  record.created_at = recently_requested and pending.created_at or os.time()
  driver.datastore[pending_key] = record
  -- Repeated imports update the pending credentials without duplicating an
  -- asynchronous creation request or postponing its next retry indefinitely.
  if recently_requested then return "requested" end
  local ok, created = pcall(driver.try_create_device, driver, {type="LAN",device_network_id=dni,
    label=cfg.label,profile=cfg.profile,manufacturer="Xiaomi",model=cfg.model,vendor_provided_label=cfg.vendor_label})
  if ok and created then return "requested" end
  record.created_at = 0
  driver.datastore[pending_key] = record -- Retain authenticated hidden-token credentials for rediscovery.
  return "failed"
end

function M.handle(driver, setup, args, status)
  if setup.model ~= "xiaomi.setup" or driver.xiaomi_enrolling then return end
  local function report(message) pcall(status, message) end
  if type(args) ~= "table" then report("연결 요청 오류"); return end
  local address, port, ticket = args.address, tonumber(args.port), args.ticket
  if not connection.valid_ip(address) or not port or port % 1 ~= 0 or port < 1 or port > 65535
    or not connection.valid_token(ticket) then report("연결 요청 오류"); return end
  driver.xiaomi_enrolling = true
  local key = (ticket:gsub("..", function(b) return string.char(tonumber(b,16)) end))
  local result, reconnect, acknowledged = nil, {}, false
  local ok = pcall(function()
    report("기기 가져오는 중")
    local started = socket.gettime()
    local bundle = exchange(address, port, key, "/bundle", {device_id=setup.id}, started + TRANSFER_TTL_S)
    assert(type(bundle) == "table" and bundle.device_id == setup.id and array_size(bundle.devices))
    local ttl = bundle.expires_in
    if ttl == nil then ttl = TRANSFER_TTL_S end -- Compatibility with an older helper.
    assert(type(ttl) == "number" and ttl > 0 and ttl <= TRANSFER_TTL_S)
    -- Start from before the exchange so transit time cannot extend the helper's expiry.
    local deadline = started + ttl
    local auth_deadline = deadline - ACK_RESERVE_S
    result = {updated=0, requested=0, failed=0}
    local seen = {}
    for _, record in ipairs(bundle.devices) do
      local cfg = record_config(record)
      local duplicate = cfg and seen[record.did]
      local outcome = "failed"
      if not duplicate then
        if cfg then seen[record.did] = true end
        local imported, value = pcall(import_record, driver, record, auth_deadline, reconnect)
        if imported then outcome = value end
      end
      result[outcome] = result[outcome] + 1
    end
    local ack = exchange(address, port, key, "/ack", {device_id=setup.id,result=result}, deadline)
    acknowledged = type(ack) == "table" and ack.ok == true
  end)
  local summary = result and string.format("연결 확인 %d · 등록 요청 %d · 실패 %d",result.updated,result.requested,result.failed)
  if ok and acknowledged then report(summary)
  elseif summary then report("완료 확인 실패 · " .. summary .. " — 로그인 도우미에서 다시 시도하세요")
  else report("연결 실패 — 로그인 도우미에서 다시 시도하세요") end
  -- Appliance refresh can take longer than the transfer ticket's lifetime.
  -- Acknowledge the saved credentials first, then attach every updated device.
  for _, device in ipairs(reconnect) do
    if discovery.on_connected then
      local attached = pcall(discovery.on_connected, driver, device)
      if attached then device:set_field("xiaomi_attach_pending", nil) end
    end
  end
  driver.xiaomi_enrolling = false
end
return M
