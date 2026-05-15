--[[
  Tuya Cloud OpenAPI client (HMAC-SHA256 signed). One client per Tuya project
  (Access ID / Access Secret). Handles token issuance + refresh, then signs
  every request with `client_id + access_token + t + nonce + stringToSign`.

  Public API:
    Client.new{ access_id=..., access_secret=..., region="us"|"eu"|"in" }
    client:get(url_path)            -> result_table, err
    client:post(url_path, body_tbl) -> result_table, err
]]

local hmac = require "crypto.hmac"
local sha = require "crypto.sha256"

-- HTTPS over cosock if available; falls back to luasec on host for tests.
local http
do
  local ok, cosock = pcall(require, "cosock")
  if ok then
    local hok, ssl_https = pcall(cosock.asyncify, "ssl.https")
    if hok then http = ssl_https end
  end
  if not http then http = require "ssl.https" end
end

local json
do
  local ok, m = pcall(require, "st.json")
  if not ok then ok, m = pcall(require, "dkjson") end
  json = m
end
local ltn12 = require "ltn12"

local Client = {}
Client.__index = Client

local REGIONS = {
  us = "openapi.tuyaus.com",
  eu = "openapi.tuyaeu.com",
  ["in"] = "openapi.tuyain.com",
  cn = "openapi.tuyacn.com",
}

local function now_ms()
  -- Lua's os.time() is seconds; Tuya needs milliseconds.
  return tostring(math.floor((os.time() + 0) * 1000))
end

local function to_hex(raw)
  local out = {}
  for i = 1, #raw do out[#out + 1] = string.format("%02x", raw:byte(i)) end
  return table.concat(out)
end

function Client.new(opts)
  assert(opts.access_id and opts.access_secret, "access_id and access_secret required")
  local region = opts.region or "us"
  local host = REGIONS[region] or region  -- allow direct hostname
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

local function raw_request(self, method, url, body, token)
  local t, nonce, sig = sign(self, method, url, body, token)
  local sink_tbl = {}
  local headers = {
    ["client_id"]   = self.access_id,
    ["t"]           = t,
    ["sign_method"] = "HMAC-SHA256",
    ["nonce"]       = nonce,
    ["sign"]        = sig,
  }
  if token then headers["access_token"] = token end
  if body then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body)
  end
  local _, code, _ = http.request{
    url = "https://" .. self.host .. url,
    method = method,
    headers = headers,
    sink = ltn12.sink.table(sink_tbl),
    source = body and ltn12.source.string(body) or nil,
  }
  local resp_body = table.concat(sink_tbl)
  if type(code) ~= "number" then
    return nil, "transport error: " .. tostring(code)
  end
  local obj, _, jerr = json.decode and json.decode(resp_body) or { success = false }
  if not obj then return nil, "json decode: " .. tostring(jerr) .. " body=" .. resp_body:sub(1, 200) end
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
  local body = json.encode and json.encode(body_tbl) or "{}"
  return raw_request(self, "POST", url, body, self._token)
end

--- Convenience: send one or more high-level Tuya commands to a device.
-- @param device_id string
-- @param commands  table list of {code=..., value=...}
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
