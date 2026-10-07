--[[
  High-level miIO/MiOT client over UDP.

  Each call sends the discovery (Hello) packet first to refresh device_id and
  the device-side stamp, then sends the encrypted JSON-RPC request and parses
  the reply. Cosock sockets are used so we cooperate with the SmartThings Edge
  scheduler; on the host (for unit-testing) plain luasocket also works since
  the API is compatible.

  Methods:
    Client.new{ ip = ..., token = ... } -> client
    client:miio_info()                  -> table | nil, err
    client:get_properties(list)         -> result_table | nil, err
        list = { {siid=2, piid=1, did="power"}, ... }
    client:set_property(siid, piid, value, did_opt) -> ok, err
    client:set_properties(list)         -> result_table | nil, err
        list = { {siid=2, piid=1, value=true, did="power"}, ... }
    client:action(siid, aiid, args_opt) -> result_table | nil, err
]]

local pkt = require "miio.packet"

-- Try cosock first (Edge runtime); fall back to luasocket on host.
local socket_mod
do
  local ok, m = pcall(require, "cosock.socket")
  if ok then socket_mod = m else socket_mod = require "socket" end
end

local json
do
  local ok, m = pcall(require, "dkjson")
  if not ok then
    ok, m = pcall(require, "st.json")
  end
  if not ok then
    -- minimal stand-in for host-side unit tests; not used inside the hub.
    m = nil
  end
  json = m
end

local PORT = 54321
local DEFAULT_TIMEOUT = 5
local MAX_RETRIES = 3

local function hex2bin(h)
  if type(h) ~= "string" or #h ~= 32 or not h:match("^%x+$") then
    return nil, "token must be exactly 32 hexadecimal characters"
  end
  return (h:gsub("..", function(b) return string.char(tonumber(b, 16)) end))
end

local Client = {}
Client.__index = Client

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

--- @param opts table { ip = "1.2.3.4", token = "32hex", timeout_s = number?, deadline = number?, expected_did = number? }
function Client.new(opts)
  if type(opts) ~= "table" or type(opts.ip) ~= "string" or opts.ip == "" or not opts.token then
    return nil, "ip and token required"
  end
  local token_bytes, token_err = hex2bin(opts.token)
  if not token_bytes then return nil, token_err end
  local timeout = opts.timeout_s
  if timeout == nil then timeout = DEFAULT_TIMEOUT end
  if not finite(timeout) or timeout <= 0 then return nil, "timeout must be positive and finite" end
  if opts.deadline ~= nil and not finite(opts.deadline) then return nil, "deadline must be finite" end
  if opts.expected_did ~= nil and (not finite(opts.expected_did) or opts.expected_did % 1 ~= 0
      or opts.expected_did <= 0 or opts.expected_did >= 0xFFFFFFFF) then
    return nil, "expected device identity must be a valid DID"
  end
  return setmetatable({
    ip = opts.ip,
    token_bytes = token_bytes,
    timeout = timeout,
    deadline = opts.deadline,
    expected_did = opts.expected_did,
    next_id = 1,
  }, Client)
end

local function remaining_timeout(self)
  if not self.deadline then return self.timeout end
  local remaining = self.deadline - socket_mod.gettime()
  if remaining <= 0 then return nil, "deadline exceeded" end
  return math.min(self.timeout, remaining)
end

local function prepare_socket(self, s)
  local timeout, err = remaining_timeout(self)
  if not timeout then return nil, err end
  local ok, socket_err = s:settimeout(timeout)
  if not ok then return nil, "timeout: " .. tostring(socket_err) end
  return true
end

local function open_socket(self)
  local timeout, deadline_err = remaining_timeout(self)
  if not timeout then return nil, deadline_err end
  local s, err = socket_mod.udp()
  if not s then return nil, "udp() failed: " .. tostring(err) end
  local ready, timeout_err = prepare_socket(self, s)
  if not ready then s:close(); return nil, timeout_err end
  local ok, serr = s:setsockname("0.0.0.0", 0)
  if not ok then s:close(); return nil, "bind failed: " .. tostring(serr) end
  return s
end

local function send_packet(self, s, body)
  local ready, err = prepare_socket(self, s)
  if not ready then return nil, err end
  local sent, send_err = s:sendto(body, self.ip, PORT)
  if not sent then return nil, "send: " .. tostring(send_err) end
  return true
end

local function receive_packet(self, s)
  local ready, err = prepare_socket(self, s)
  if not ready then return nil, err end
  local raw, address, port = s:receivefrom()
  if not raw then return nil, "receive: " .. tostring(address) end
  if address ~= self.ip or tonumber(port) ~= PORT then return nil, "unexpected reply source" end
  local timeout, deadline_err = remaining_timeout(self)
  if not timeout then return nil, deadline_err end
  return raw
end

local function parse_hello(self, raw)
  if #raw ~= 32 then return nil, nil, "invalid hello size" end
  local dev_id, stamp, _, err = pkt.parse(self.token_bytes, raw)
  if err then return nil, nil, "parse: " .. err end
  if dev_id == 0 or dev_id == 0xFFFFFFFF then return nil, nil, "invalid hello identity" end
  if self.expected_did and dev_id ~= self.expected_did then return nil, nil, "device identity changed" end
  return dev_id, stamp
end

--- Send a Hello packet and return device_id, stamp (or nil, err).
function Client:handshake()
  local s, err = open_socket(self)
  if not s then return nil, nil, err end
  local ok, serr = send_packet(self, s, pkt.hello_packet())
  if not ok then s:close(); return nil, nil, serr end
  local resp, receive_err = receive_packet(self, s)
  s:close()
  if not resp then return nil, nil, receive_err end
  return parse_hello(self, resp)
end

--- Start a session: do one handshake and return an immutable session value.
-- Keeping the session local to a refresh prevents a concurrently spawned set
-- command from replacing or clearing another operation's cached stamp.
function Client:begin_session()
  local dev_id, stamp, err = self:handshake()
  if not dev_id then return nil, err end
  return {
    dev_id = dev_id,
    base_stamp = stamp,
    base_time = os.time(),
  }
end

local function session_dev_stamp(session)
  if not session then return nil, nil end
  return session.dev_id, session.base_stamp + (os.time() - session.base_time)
end

-- One attempt of: (optional hello) → request → reply. Returns (payload, err).
local function send_once(self, json_body, session, expected_dev_id)
  local s, oerr = open_socket(self)
  if not s then return nil, oerr end

  local dev_id, stamp
  if session then
    dev_id, stamp = session_dev_stamp(session)
  else
    local sent, send_err = send_packet(self, s, pkt.hello_packet())
    if not sent then s:close(); return nil, send_err end
    local hello, receive_err = receive_packet(self, s)
    if not hello then s:close(); return nil, receive_err end
    local parse_err
    dev_id, stamp, parse_err = parse_hello(self, hello)
    if not dev_id then s:close(); return nil, parse_err end
  end
  if expected_dev_id and dev_id ~= expected_dev_id then s:close(); return nil, "device identity changed" end

  local req = pkt.build(self.token_bytes, dev_id, stamp, json_body)
  local ok, serr = send_packet(self, s, req)
  if not ok then s:close(); return nil, serr end
  local rep, receive_err = receive_packet(self, s)
  s:close()
  if not rep then return nil, receive_err end
  local reply_dev_id, _, payload, perr = pkt.parse(self.token_bytes, rep)
  if perr then return nil, "rpc parse: " .. perr end
  if reply_dev_id ~= dev_id then return nil, "reply device identity mismatch" end
  if not payload then return nil, "empty RPC reply" end
  return payload
end

--- Low-level: send a JSON-RPC body and return the decrypted reply string.
function Client:send_raw(json_body, session)
  local last_err = "unknown"
  local active_session = session
  local expected_dev_id = self.expected_did or (session and session.dev_id)
  for attempt = 1, MAX_RETRIES do
    local payload, err = send_once(self, json_body, active_session, expected_dev_id)
    if payload then return payload end
    last_err = err
    if err == "deadline exceeded" then break end
    -- A failed RPC may mean the cached stamp is stale. Retry with a fresh
    -- handshake without mutating the caller's session value.
    active_session = nil
  end
  return nil, last_err
end

local function make_body(id, method, params)
  -- params must already be a serialized JSON array string
  return string.format('{"id":%d,"method":"%s","params":%s}', id, method, params)
end

--- Encode a Lua value to JSON literal. Limited types: bool/number/string.
-- Returns string suitable for inlining into a JSON document.
local function encode_value(v)
  local t = type(v)
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v then return "null" end  -- NaN
    if math.type and math.type(v) == "integer" then return tostring(v) end
    return tostring(v)
  end
  if t == "string" then
    -- Minimal JSON string escape; miIO values are simple ASCII/UTF-8.
    local esc = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. esc .. '"'
  end
  if v == nil then return "null" end
  error("cannot encode value of type " .. t)
end

--- Parse a JSON-RPC reply string. Returns (result, err).
function Client:_parse_reply(payload, expected_id)
  if not payload then return nil, "empty payload" end
  if json and json.decode then
    local ok, obj, position, jerr = pcall(json.decode, payload)
    if not ok or type(obj) ~= "table" or jerr then return nil, "invalid JSON-RPC response" end
    if type(position) == "number" and payload:sub(position):match("%S") then return nil, "invalid JSON-RPC response" end
    if expected_id and obj.id ~= expected_id then return nil, "reply request identity mismatch" end
    if obj.error then
      local e = obj.error
      if type(e) ~= "table" then return nil, "invalid JSON-RPC error" end
      return nil, string.format("device error %s: %s",
        tostring(e.code or "?"), tostring(e.message or ""))
    end
    if type(obj.result) ~= "table" then return nil, "invalid JSON-RPC result" end
    return obj.result
  end
  -- Fallback: return raw payload string (host-side test).
  return payload
end

function Client:next_request_id()
  local id = self.next_id
  self.next_id = (id % 0x7FFFFFFF) + 1
  return id
end

function Client:miio_info(session)
  local id = self:next_request_id()
  local body = make_body(id, "miIO.info", "[]")
  local resp, err = self:send_raw(body, session)
  if not resp then return nil, err end
  return self:_parse_reply(resp, id)
end

local function result_list(result, requested, reads)
  if type(result) ~= "table" or #result == 0 then return nil, "empty property/action result" end
  for key, item in pairs(result) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #result or type(item) ~= "table" then
      return nil, "invalid property/action result"
    end
  end
  local seen = {}
  for index = 1, #result do
    local item = result[index]
    if type(item) ~= "table" then return nil, "invalid property/action result" end
    local code = tonumber(item.code)
    if not finite(code) or code % 1 ~= 0 then return nil, "invalid property/action result code" end
    if requested then
      local prop = requested[item.did]
      if not prop or seen[item.did] then return nil, "property/action result identity mismatch" end
      if (item.siid ~= nil and item.siid ~= prop.siid)
          or (prop.piid and item.piid ~= nil and item.piid ~= prop.piid)
          or (prop.aiid and item.aiid ~= nil and item.aiid ~= prop.aiid) then
        return nil, "property/action result identity mismatch"
      end
      seen[item.did] = true
    end
    if reads and code == 0 then
      local kind = type(item.value)
      if kind ~= "boolean" and kind ~= "string" and not finite(item.value) then
        return nil, "invalid property result value"
      end
    end
  end
  return result
end

--- @param props table list of {siid=, piid=, did=opt}
function Client:get_properties(props, session)
  local entries, requested = {}, {}
  for _, p in ipairs(props) do
    local did = p.did or string.format("%d-%d", p.siid, p.piid)
    requested[did] = p
    entries[#entries + 1] = string.format(
      '{"did":%s,"siid":%d,"piid":%d}', encode_value(did), p.siid, p.piid)
  end
  local params = "[" .. table.concat(entries, ",") .. "]"
  local id = self:next_request_id()
  local body = make_body(id, "get_properties", params)
  local resp, err = self:send_raw(body, session)
  if not resp then return nil, err end
  local result, parse_err = self:_parse_reply(resp, id)
  if not result then return nil, parse_err end
  -- Successful partial reads remain useful; only returned entries must match.
  return result_list(result, requested, true)
end

--- @param props table list of {siid=, piid=, value=, did=opt}
function Client:set_properties(props)
  local entries, requested = {}, {}
  for _, p in ipairs(props) do
    local did = p.did or string.format("%d-%d", p.siid, p.piid)
    requested[did] = p
    entries[#entries + 1] = string.format(
      '{"did":%s,"siid":%d,"piid":%d,"value":%s}',
      encode_value(did), p.siid, p.piid, encode_value(p.value))
  end
  local params = "[" .. table.concat(entries, ",") .. "]"
  local id = self:next_request_id()
  local body = make_body(id, "set_properties", params)
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  local result, parse_err = self:_parse_reply(resp, id)
  if not result then return nil, parse_err end
  return result_list(result, requested)
end

function Client:set_property(siid, piid, value, did)
  did = did or string.format("%d-%d", siid, piid)
  local result, err = self:set_properties({
    { siid = siid, piid = piid, value = value, did = did }
  })
  if not result then return nil, err end
  if type(result) ~= "table" or #result == 0 then
    return nil, "set_properties returned no result"
  end
  for _, item in ipairs(result) do
    if type(item) ~= "table" then return nil, "invalid set_properties result" end
    if item.did ~= did or (item.siid ~= nil and item.siid ~= siid)
        or (item.piid ~= nil and item.piid ~= piid) then
      return nil, "property/action result identity mismatch"
    end
    local code = tonumber(item.code)
    if code ~= 0 then
      return nil, string.format(
        "set_properties failed for %s (code %s)",
        tostring(item.did or did or (siid .. "-" .. piid)),
        tostring(item.code or "missing"))
    end
  end
  return true
end

function Client:action(siid, aiid, args, did)
  did = did or string.format("act-%d-%d", siid, aiid)
  local in_arr = "[]"
  if args and #args > 0 then
    local parts = {}
    for _, v in ipairs(args) do parts[#parts + 1] = encode_value(v) end
    in_arr = "[" .. table.concat(parts, ",") .. "]"
  end
  local params = string.format(
    '[{"did":%s,"siid":%d,"aiid":%d,"in":%s}]',
    encode_value(did), siid, aiid, in_arr)
  local id = self:next_request_id()
  local body = make_body(id, "action", params)
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  local result, parse_err = self:_parse_reply(resp, id)
  if not result then return nil, parse_err end
  local _, list_err = result_list(result, {[did] = {siid = siid, aiid = aiid}})
  if list_err then return nil, list_err end
  for _, item in ipairs(result) do
    local code = tonumber(item.code)
    if code ~= 0 then
      return nil, string.format(
        "action failed for %s (code %s)",
        tostring(item.did or did), tostring(item.code or "missing"))
    end
  end
  return true
end

return Client
