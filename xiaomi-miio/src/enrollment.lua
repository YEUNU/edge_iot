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

local function exchange(address, port, key, path, value)
  local sock = assert(socket.tcp())
  sock:settimeout(10)
  local ok, result = pcall(function()
    assert(sock:connect(address, port))
    local body = packet.build(key, 1, os.time(), json.encode(value))
    local request = "POST " .. path .. " HTTP/1.1\r\nHost: " .. address ..
      "\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
    local offset = 1
    while offset <= #request do
      local sent, _, last = sock:send(request, offset)
      assert(sent or (last and last >= offset), "send failed")
      offset = (sent or last) + 1
    end
    local status = assert(sock:receive("*l"))
    assert(status:match("^HTTP/%d%.%d 200 "), "enrollment rejected")
    local length
    for i = 1, 32 do
      local line = assert(sock:receive("*l"))
      if line == "" then break end
      length = tonumber(line:lower():match("^content%-length:%s*(%d+)$")) or length
      assert(i < 32, "too many headers")
    end
    assert(length and length > 32 and length <= 16384, "invalid size")
    local _, _, plaintext, err = packet.parse(key, assert(sock:receive(length)))
    assert(plaintext and not err, "invalid encrypted reply")
    return assert(json.decode(plaintext))
  end)
  sock:close()
  if ok then return result end
  return nil -- Never log credential-bearing response text or parser errors.
end

function M.handle(driver, setup, args, status)
  if setup.model ~= "xiaomi.setup" or driver.xiaomi_enrolling then return end
  local address, port, ticket = args.address, tonumber(args.port), args.ticket
  if not connection.valid_ip(address) or not port or port % 1 ~= 0 or port < 1 or port > 65535
    or not connection.valid_token(ticket) then status("연결 요청 오류"); return end
  driver.xiaomi_enrolling = true
  local key = (ticket:gsub("..", function(b) return string.char(tonumber(b,16)) end))
  local ok = pcall(function()
    status("기기 가져오는 중")
    local bundle = exchange(address, port, key, "/bundle", {device_id=setup.id})
    assert(bundle and bundle.device_id == setup.id and type(bundle.devices) == "table" and #bundle.devices <= 20)
    local result = {updated=0, requested=0, failed=0}
    for _, record in ipairs(bundle.devices) do
      local cfg = models[record.model]
      local valid = cfg and connection.valid_ip(record.ip) and connection.valid_token(record.token)
        and type(record.did) == "number" and record.did > 0 and record.did < 0xFFFFFFFF and record.did % 1 == 0
      if valid then
        local client = assert(Client.new{ip=record.ip,token=record.token,timeout_s=2})
        local did = client:handshake()
        local info = did == record.did and client:miio_info() or nil
        valid = type(info) == "table" and info.model == record.model
      end
      if valid then
        local existing
        for _, device in ipairs(driver:get_devices()) do
          local saved = device:get_field("local_connection") or {}
          local prefs = connection.get(device)
          if saved.did == record.did or (device.model == record.model and prefs.deviceIp == record.ip)
            or device.device_network_id == "xiaomi-miio-" .. record.did then existing = device; break end
        end
        -- Record that this imported key supersedes the old preference value.
        if existing then
          record.preference_token = (existing.preferences or {}).deviceToken
          connection.save(existing, record)
          if discovery.on_connected then discovery.on_connected(driver, existing) end
          result.updated = result.updated + 1
        else
          local dni = "xiaomi-miio-" .. record.did
          record.created_at = os.time()
          driver.datastore["discovered:" .. dni] = record
          local created = driver:try_create_device({type="LAN",device_network_id=dni,
            label=cfg.label,profile=cfg.profile,manufacturer="Xiaomi",model=cfg.model,vendor_provided_label=cfg.vendor_label})
          if created then result.requested = result.requested + 1
          else driver.datastore["discovered:" .. dni] = nil; result.failed = result.failed + 1 end
        end
      else result.failed = result.failed + 1 end
    end
    exchange(address, port, key, "/ack", {device_id=setup.id,result=result})
    status(string.format("연결 확인 %d · 등록 요청 %d · 실패 %d",result.updated,result.requested,result.failed))
  end)
  driver.xiaomi_enrolling = false
  if not ok then status("연결 실패 — 로그인 도우미에서 다시 시도하세요") end
end
return M
