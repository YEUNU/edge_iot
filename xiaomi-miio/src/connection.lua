-- Manual preferences override discovered credentials only when valid.
local M = {}
function M.valid_token(value)
  return type(value) == "string" and #value == 32 and value:match("^%x+$") ~= nil
    and value ~= string.rep("0", 32) and value:lower() ~= string.rep("f", 32)
end
function M.valid_ip(value)
  if type(value) ~= "string" then return false end
  local a,b,c,d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, n in ipairs({a,b,c,d}) do if tonumber(n) > 255 then return false end end
  return tonumber(a) > 0 and tonumber(a) < 224 and value ~= "127.0.0.1"
end
function M.get(device)
  local prefs = device.preferences or {}
  local saved = device:get_field("local_connection") or {}
  local ip = saved.ip or prefs.deviceIp
  local token = M.valid_token(prefs.deviceToken) and prefs.deviceToken or saved.token
  if saved.preference_token == prefs.deviceToken and M.valid_token(saved.token) then token = saved.token end
  return { deviceIp = ip, deviceToken = token }
end
function M.complete(prefs)
  return M.valid_ip(prefs.deviceIp) and M.valid_token(prefs.deviceToken)
end
function M.save(device, record)
  device:set_field("local_connection", record, {persist = true})
end
return M
