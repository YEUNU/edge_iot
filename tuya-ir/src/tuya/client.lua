--[[
  Tuya Cloud OpenAPI client (HMAC-SHA256 signed). Built on cosock TCP + SSL wrap
  + manual HTTP since SmartThings Edge does not expose `ssl.https`.
]]

local hmac = require "crypto.hmac"
local sha = require "crypto.sha256"
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local log = require "log"

-- Try multiple possible DNS module locations. cosock wraps luasocket but only
-- exposes some submodules; on real hub firmware different paths work.
local function find_dns()
  for _, name in ipairs({ "cosock.dns", "cosock.socket.dns", "socket.dns" }) do
    local ok, m = pcall(require, name)
    if ok and m and m.toip then
      log.info("tuya: resolved DNS module via " .. name)
      return m
    end
  end
  -- Last resort: socket itself sometimes has dns attached.
  if socket and socket.dns and socket.dns.toip then
    log.info("tuya: resolved DNS module via cosock.socket.dns attribute")
    return socket.dns
  end
  return nil
end
local dns = find_dns()

local json
do
  local ok, m = pcall(require, "st.json")
  if not ok then ok, m = pcall(require, "dkjson") end
  json = m
end

local Client = {}
Client.__index = Client

local REGIONS = {
  us = "openapi.tuyaus.com",
  eu = "openapi.tuyaeu.com",
  ["in"] = "openapi.tuyain.com",
  cn = "openapi.tuyacn.com",
}

local PORT = 443
local TIMEOUT = 10

-- DNS-over-HTTPS via Cloudflare. 1.1.1.1 is an anycast IP so no bootstrap
-- DNS is needed. Cache results until their TTL expires.
local DOH_IP = "1.1.1.1"
local _dns_cache = {}

local function now_ms()
  return tostring(math.floor(os.time() * 1000))
end

function Client.new(opts)
  assert(opts.access_id and opts.access_secret, "access_id and access_secret required")
  local region = (opts.region or "us"):lower()
  local host = REGIONS[region] or region
  return setmetatable({
    access_id = opts.access_id,
    access_secret = opts.access_secret,
    host = host,
    _token = nil,
    _token_exp = 0,
  }, Client)
end

local function sign(self, method, url, body, token)
  local t = now_ms()
  local nonce = ""
  local body_sha = sha.hex(body or "")
  local str_to_sign = method .. "\n" .. body_sha .. "\n\n" .. url
  local sign_input = self.access_id .. (token or "") .. t .. nonce .. str_to_sign
  local sig = hmac.sha256_hex(self.access_secret, sign_input):upper()
  return t, nonce, sig
end

-- Low-level TLS connect to an IP address. No DNS, no hostname.
local function connect_tls_ip(ip)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp(): " .. tostring(err) end
  err = select(2, sock:settimeout(TIMEOUT))
  if err then sock:close(); return nil, "settimeout: " .. tostring(err) end
  local ok, cerr = sock:connect(ip, PORT)
  if not ok then sock:close(); return nil, "connect(" .. ip .. "): " .. tostring(cerr) end
  local wrapped, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
  if not wrapped then sock:close(); return nil, "ssl.wrap: " .. tostring(werr) end
  err = select(2, wrapped:settimeout(TIMEOUT))
  if err then wrapped:close(); return nil, "settimeout(ssl): " .. tostring(err) end
  err = select(2, wrapped:dohandshake())
  if err then wrapped:close(); return nil, "dohandshake: " .. tostring(err) end
  return wrapped
end

local function send_all_sock(sock, data)
  local sent, err, idx = nil, nil, 0
  repeat sent, err, idx = sock:send(data, idx + 1, #data)
  until sent == #data or err ~= nil
  return err
end

-- Forward-declared so DoH can use the response parser before it's defined.
local read_response

-- Resolve a hostname → IPv4 via Cloudflare DoH. Returns ip, ttl, err.
local function doh_resolve(name)
  local sock, err = connect_tls_ip(DOH_IP)
  if not sock then return nil, nil, "doh connect: " .. tostring(err) end
  local req = "GET /dns-query?name=" .. name .. "&type=A HTTP/1.1\r\n"
           .. "Host: cloudflare-dns.com\r\n"
           .. "Accept: application/dns-json\r\n"
           .. "Connection: close\r\n\r\n"
  local serr = send_all_sock(sock, req)
  if serr then sock:close(); return nil, nil, "doh send: " .. tostring(serr) end
  local status, body, rerr = read_response(sock)
  sock:close()
  if rerr then return nil, nil, "doh recv: " .. tostring(rerr) end
  if status ~= 200 then return nil, nil, "doh http " .. tostring(status) end
  if not (json and json.decode) then return nil, nil, "no json decoder" end
  local obj, _, jerr = json.decode(body)
  if not obj then return nil, nil, "doh json: " .. tostring(jerr) end
  local best_ttl = 60
  for _, ans in ipairs(obj.Answer or {}) do
    -- type 1 = A record
    if ans.type == 1 and ans.data then
      best_ttl = ans.TTL or best_ttl
      return ans.data, best_ttl
    end
  end
  return nil, nil, "doh: no A record for " .. name
end

local function resolve(host)
  if not host:match("[a-zA-Z]") then return host end  -- already IP
  local now = os.time()
  local c = _dns_cache[host]
  if c and now < c.expires then return c.ip end
  local ip, ttl, err = doh_resolve(host)
  if not ip then return nil, err end
  _dns_cache[host] = { ip = ip, expires = now + math.max(ttl or 60, 60) }
  return ip
end

-- Open a fresh TLS connection to the Tuya host, return wrapped socket.
local function connect_tls(host)
  local ip, derr = resolve(host)
  if not ip then return nil, "dns: " .. tostring(derr) end
  return connect_tls_ip(ip)
end

local send_all = send_all_sock

-- Read HTTP response: status line, headers, body. Returns status_code, body (string), err.
read_response = function(sock)
  -- Status line
  local line, err = sock:receive("*l")
  if not line then return nil, nil, "no status line: " .. tostring(err) end
  local status = tonumber(line:match("HTTP/%d+%.%d+ (%d+)"))
  if not status then return nil, nil, "bad status line: " .. line end

  -- Headers
  local content_length, chunked = 0, false
  while true do
    local hl, herr = sock:receive("*l")
    if not hl then return nil, nil, "header read: " .. tostring(herr) end
    if hl == "" then break end
    local k, v = hl:match("^([^:]+):%s*(.+)$")
    if k then
      local lk = k:lower()
      if lk == "content-length" then content_length = tonumber(v) or 0
      elseif lk == "transfer-encoding" and v:lower():find("chunked") then chunked = true end
    end
  end

  -- Body
  local body
  if chunked then
    local parts = {}
    while true do
      local size_line, rerr = sock:receive("*l")
      if not size_line then return nil, nil, "chunk size: " .. tostring(rerr) end
      local size = tonumber(size_line:match("^[0-9a-fA-F]+"), 16) or 0
      if size == 0 then break end
      local chunk, cerr = sock:receive(size)
      if not chunk then return nil, nil, "chunk body: " .. tostring(cerr) end
      parts[#parts + 1] = chunk
      sock:receive("*l")  -- trailing CRLF
    end
    body = table.concat(parts)
  elseif content_length > 0 then
    body, err = sock:receive(content_length)
    if not body then return nil, nil, "body read: " .. tostring(err) end
  else
    body = ""
  end
  return status, body
end

local function raw_request(self, method, url, body, token)
  local t, nonce, sig = sign(self, method, url, body, token)
  local headers = {
    "Host: " .. self.host,
    "User-Agent: smartthings-edge-tuya-ir/1.0",
    "client_id: " .. self.access_id,
    "t: " .. t,
    "sign_method: HMAC-SHA256",
    "nonce: " .. nonce,
    "sign: " .. sig,
    "Accept: application/json",
    "Connection: close",
  }
  if token then headers[#headers + 1] = "access_token: " .. token end
  if body then
    headers[#headers + 1] = "Content-Type: application/json"
    headers[#headers + 1] = "Content-Length: " .. tostring(#body)
  else
    body = ""
  end

  local req = method .. " " .. url .. " HTTP/1.1\r\n"
            .. table.concat(headers, "\r\n") .. "\r\n\r\n"
            .. body

  local sock, cerr = connect_tls(self.host)
  if not sock then return nil, "connect: " .. tostring(cerr) end
  local serr = send_all(sock, req)
  if serr then sock:close(); return nil, "send: " .. tostring(serr) end
  local status, resp_body, rerr = read_response(sock)
  sock:close()
  if rerr then return nil, "recv: " .. tostring(rerr) end
  if status >= 400 then return nil, "http " .. status .. ": " .. (resp_body or ""):sub(1, 200) end

  if not (json and json.decode) then return nil, "no json decoder" end
  local obj, _, jerr = json.decode(resp_body)
  if not obj then return nil, "json decode: " .. tostring(jerr) end
  if obj.success == false then
    return nil, string.format("api %s: %s", tostring(obj.code), tostring(obj.msg))
  end
  return obj.result
end

function Client:_ensure_token()
  if self._token and os.time() < self._token_exp - 60 then return true end
  local result, err = raw_request(self, "GET", "/v1.0/token?grant_type=1")
  if not result then return false, "token fetch: " .. tostring(err) end
  self._token = result.access_token
  self._token_exp = os.time() + (result.expire_time or 3600)
  return true
end

function Client:get(url)
  local ok, err = self:_ensure_token()
  if not ok then return nil, err end
  return raw_request(self, "GET", url, nil, self._token)
end

function Client:post(url, body_tbl)
  local ok, err = self:_ensure_token()
  if not ok then return nil, err end
  if not (json and json.encode) then return nil, "no json encoder" end
  local body = json.encode(body_tbl)
  return raw_request(self, "POST", url, body, self._token)
end

function Client:send_commands(device_id, commands)
  return self:post("/v1.0/devices/" .. device_id .. "/commands", { commands = commands })
end

function Client:get_status(device_id)
  return self:get("/v1.0/devices/" .. device_id .. "/status")
end

function Client:get_device(device_id)
  return self:get("/v1.0/devices/" .. device_id)
end

return Client
