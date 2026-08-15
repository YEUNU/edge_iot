local root, model = ...
assert(root and model, "usage: lua tests/miot_live_read.lua <repo-root> <model>")

package.path = table.concat({
  root .. "/xiaomi-miio/src/?.lua",
  root .. "/xiaomi-miio/src/?/?.lua",
  package.path,
}, ";")

local json = require "dkjson"
local Client = require "miio.client"

local raw = io.read("*a")
local prefs, _, decode_err = json.decode(raw)
assert(prefs, decode_err)
prefs = prefs.values or prefs

local function preference_value(value)
  if type(value) == "table" then return value.value end
  return value
end

local ip = preference_value(prefs.deviceIp)
local token = preference_value(prefs.deviceToken)
assert(type(ip) == "string" and type(token) == "string", "missing device preferences")

local model_configs = {
  ["zhimi.fan.za5"] = {
    chunk_size = 4,
    props = {
      { siid = 2, piid = 1, did = "power" },
      { siid = 6, piid = 8, did = "speed-percent" },
      { siid = 2, piid = 3, did = "swing" },
      { siid = 2, piid = 5, did = "angle" },
      { siid = 2, piid = 7, did = "fan-mode" },
      { siid = 2, piid = 10, did = "power-off-delay" },
      { siid = 3, piid = 1, did = "lock" },
      { siid = 4, piid = 3, did = "indicator" },
      { siid = 5, piid = 1, did = "alarm" },
      { siid = 7, piid = 1, did = "humidity" },
      { siid = 7, piid = 7, did = "temperature" },
    },
  },
  ["zhimi.airp.cpa4"] = {
    chunk_size = 2,
    props = {
      { siid = 2, piid = 1, did = "power" },
      { siid = 2, piid = 4, did = "mode" },
      { siid = 2, piid = 2, did = "fault" },
      { siid = 3, piid = 4, did = "pm25" },
      { siid = 4, piid = 1, did = "filter-life" },
      { siid = 4, piid = 3, did = "filter-used-time" },
      { siid = 4, piid = 4, did = "filter-left-time" },
      { siid = 6, piid = 1, did = "alarm" },
      { siid = 8, piid = 1, did = "lock" },
      { siid = 13, piid = 2, did = "brightness" },
      { siid = 9, piid = 11, did = "favorite-level" },
    },
  },
  ["xiaomi.derh.13l"] = {
    chunk_size = 4,
    props = {
      { siid = 2, piid = 1, did = "power" },
      { siid = 2, piid = 3, did = "mode" },
      { siid = 2, piid = 2, did = "fault" },
      { siid = 2, piid = 5, did = "target" },
      { siid = 3, piid = 1, did = "humidity" },
      { siid = 3, piid = 2, did = "temperature" },
      { siid = 4, piid = 1, did = "alarm" },
      { siid = 5, piid = 2, did = "led" },
      { siid = 6, piid = 1, did = "lock" },
    },
  },
}

local client, client_err = Client.new{ ip = ip, token = token, timeout_s = 10 }
assert(client, client_err)
local session, session_err = client:begin_session()
assert(session, session_err)
local config = assert(model_configs[model], "unsupported model")
for first = 1, #config.props, config.chunk_size do
  local chunk = {}
  for index = first, math.min(first + config.chunk_size - 1, #config.props) do
    chunk[#chunk + 1] = config.props[index]
  end
  local result, request_err = client:get_properties(chunk, session)
  assert(result, request_err)
  for _, item in ipairs(result) do
    assert(tonumber(item.code) == 0,
      string.format("%s failed with code %s", tostring(item.did), tostring(item.code)))
    print(string.format("%s=%s", tostring(item.did), tostring(item.value)))
  end
end
