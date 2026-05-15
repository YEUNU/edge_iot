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
  return (h:gsub("..", function(b) return string.char(tonumber(b, 16)) end))
end

local Client = {}
Client.__index = Client

--- @param opts table { ip = "1.2.3.4", token = "32hex", timeout_s = number? }
function Client.new(opts)
  assert(opts and opts.ip and opts.token, "ip and token required")
  return setmetatable({
    ip = opts.ip,
    token_bytes = hex2bin(opts.token),
    timeout = opts.timeout_s or DEFAULT_TIMEOUT,
    next_id = 1,
  }, Client)
end

local function open_socket(timeout)
  local s, err = socket_mod.udp()
  if not s then return nil, "udp() failed: " .. tostring(err) end
  s:settimeout(timeout)
  local ok, serr = s:setsockname("0.0.0.0", 0)
  if not ok then s:close(); return nil, "bind failed: " .. tostring(serr) end
  return s
end

--- Send a Hello packet and return device_id, stamp (or nil, err).
function Client:handshake()
  local s, err = open_socket(self.timeout)
  if not s then return nil, nil, err end
  local ok, serr = s:sendto(pkt.hello_packet(), self.ip, PORT)
  if not ok then s:close(); return nil, nil, "send: " .. tostring(serr) end
  local resp = s:receivefrom()
  s:close()
  if not resp then return nil, nil, "no hello reply" end
  local dev_id, stamp, _, perr = pkt.parse(self.token_bytes, resp)
  if perr then return nil, nil, "parse: " .. perr end
  return dev_id, stamp
end

--- Start a session: do one handshake and cache device_id + stamp offset so
-- subsequent send_raw calls skip the hello round-trip.
function Client:begin_session()
  local dev_id, stamp, err = self:handshake()
  if not dev_id then return false, err end
  self._session = {
    dev_id = dev_id,
    base_stamp = stamp,
    base_time = os.time(),
  }
  return true
end

function Client:end_session()
  self._session = nil
end

local function session_dev_stamp(self)
  local s = self._session
  if not s then return nil, nil end
  return s.dev_id, s.base_stamp + (os.time() - s.base_time)
end

-- One attempt of: (optional hello) → request → reply. Returns (payload, err).
local function send_once(self, json_body)
  local s, oerr = open_socket(self.timeout)
  if not s then return nil, oerr end

  local dev_id, stamp
  if self._session then
    dev_id, stamp = session_dev_stamp(self)
  else
    s:sendto(pkt.hello_packet(), self.ip, PORT)
    local hello = s:receivefrom()
    if not hello then s:close(); return nil, "hello timeout" end
    dev_id, stamp = pkt.parse(self.token_bytes, hello)
    if not dev_id then s:close(); return nil, "hello parse" end
  end

  local req = pkt.build(self.token_bytes, dev_id, stamp, json_body)
  local ok, serr = s:sendto(req, self.ip, PORT)
  if not ok then s:close(); return nil, "send: " .. tostring(serr) end
  local rep = s:receivefrom()
  s:close()
  if not rep then return nil, "rpc timeout" end
  local _, _, payload, perr = pkt.parse(self.token_bytes, rep)
  if perr then return nil, "rpc parse: " .. perr end
  return payload
end

--- Low-level: send a JSON-RPC body and return the decrypted reply string.
function Client:send_raw(json_body)
  local last_err = "unknown"
  for attempt = 1, MAX_RETRIES do
    local payload, err = send_once(self, json_body)
    if payload then return payload end
    last_err = err
    -- If we're in a session and the RPC failed, the cached stamp may be stale.
    -- Drop it; the next attempt will perform a fresh handshake.
    if self._session and attempt < MAX_RETRIES then
      self._session = nil
    end
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
function Client:_parse_reply(payload)
  if not payload then return nil, "empty payload" end
  if json and json.decode then
    local obj, _, jerr = json.decode(payload)
    if not obj then return nil, "json decode: " .. tostring(jerr) end
    if obj.error then
      local e = obj.error
      return nil, string.format("device error %s: %s",
        tostring(e.code or "?"), tostring(e.message or ""))
    end
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

function Client:miio_info()
  local body = make_body(self:next_request_id(), "miIO.info", "[]")
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  return self:_parse_reply(resp)
end

--- @param props table list of {siid=, piid=, did=opt}
function Client:get_properties(props)
  local entries = {}
  for _, p in ipairs(props) do
    local did = p.did or string.format("%d-%d", p.siid, p.piid)
    entries[#entries + 1] = string.format(
      '{"did":%s,"siid":%d,"piid":%d}', encode_value(did), p.siid, p.piid)
  end
  local params = "[" .. table.concat(entries, ",") .. "]"
  local body = make_body(self:next_request_id(), "get_properties", params)
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  return self:_parse_reply(resp)
end

--- @param props table list of {siid=, piid=, value=, did=opt}
function Client:set_properties(props)
  local entries = {}
  for _, p in ipairs(props) do
    local did = p.did or string.format("%d-%d", p.siid, p.piid)
    entries[#entries + 1] = string.format(
      '{"did":%s,"siid":%d,"piid":%d,"value":%s}',
      encode_value(did), p.siid, p.piid, encode_value(p.value))
  end
  local params = "[" .. table.concat(entries, ",") .. "]"
  local body = make_body(self:next_request_id(), "set_properties", params)
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  return self:_parse_reply(resp)
end

function Client:set_property(siid, piid, value, did)
  return self:set_properties({ { siid = siid, piid = piid, value = value, did = did } })
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
  local body = make_body(self:next_request_id(), "action", params)
  local resp, err = self:send_raw(body)
  if not resp then return nil, err end
  return self:_parse_reply(resp)
end

return Client
