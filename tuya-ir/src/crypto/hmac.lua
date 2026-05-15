--[[
  HMAC-SHA256 over our pure-Lua sha256 module. RFC 2104.
  hmac.sha256_hex(key, msg) -> 64-char lowercase hex string
]]

local sha256 = require "crypto.sha256"
local M = {}

local BLOCK = 64

function M.sha256_raw(key, msg)
  if #key > BLOCK then key = sha256.sum(key) end
  if #key < BLOCK then key = key .. string.rep("\0", BLOCK - #key) end
  local opad, ipad = {}, {}
  for i = 1, BLOCK do
    local b = key:byte(i)
    ipad[i] = string.char(b ~ 0x36)
    opad[i] = string.char(b ~ 0x5C)
  end
  local inner = sha256.sum(table.concat(ipad) .. msg)
  return sha256.sum(table.concat(opad) .. inner)
end

function M.sha256_hex(key, msg)
  local raw = M.sha256_raw(key, msg)
  local hex = {}
  for i = 1, #raw do hex[#hex + 1] = string.format("%02x", raw:byte(i)) end
  return table.concat(hex)
end

return M
