-- Local miIO discovery. Hello checksum bytes are only a token candidate;
-- callers MUST authenticate an encrypted RPC before trusting them.
local packet = require "miio.packet"
local ok, socket = pcall(require, "cosock.socket")
if not ok then socket = require "socket" end
local M = {}

function M.parse(raw, ip, port)
  if type(raw) ~= "string" or #raw ~= 32 or port ~= 54321 then return nil end
  local did, stamp, _, err = packet.parse(nil, raw)
  if err or not did or did == 0 or did == 0xFFFFFFFF then return nil end
  local bytes = raw:sub(17, 32)
  local token
  if bytes ~= string.rep("\0", 16) and bytes ~= string.rep("\255", 16) then
    token = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  return { ip = ip, did = did, stamp = stamp, token = token }
end

function M.scan(addresses, should_continue)
  should_continue = should_continue or function() return true end
  local s, err = socket.udp()
  if not s then return {}, err end
  local bound, bind_err = s:setsockname("0.0.0.0", 0)
  if not bound then s:close(); return {}, bind_err end
  s:settimeout(0.25)
  local broadcast, broadcast_err = s:setoption("broadcast", true)
  if not broadcast then s:close(); return {}, broadcast_err end
  local targets = { ["255.255.255.255"] = true }
  for _, ip in ipairs(addresses or {}) do targets[ip] = true end
  local results, seen = {}, {}
  -- Repeat because some devices ignore the first broadcast while asleep.
  for _ = 1, 2 do
    if not should_continue() then break end
    for ip in pairs(targets) do s:sendto(packet.hello_packet(), ip, 54321) end
    local deadline = socket.gettime() + 2
    while should_continue() and socket.gettime() < deadline do
      local raw, ip, port = s:receivefrom()
      local item = M.parse(raw, ip, port)
      if item then
        local key = tostring(item.did) .. "@" .. item.ip
        if not seen[key] then seen[key] = true; results[#results + 1] = item end
      end
    end
  end
  s:close()
  return results
end
return M
