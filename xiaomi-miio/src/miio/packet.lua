--[[
  miIO binary packet encoder/decoder.

  Packet layout (32-byte header + variable encrypted payload):
    [0..2)   magic      = 0x2131
    [2..4)   length     = total packet length, big-endian uint16
    [4..8)   unknown    = 0x00000000 for normal packets, 0xFFFFFFFF for handshake
    [8..12)  device_id  = big-endian uint32 (from device handshake reply)
    [12..16) stamp      = big-endian uint32, device-side seconds
    [16..32) checksum   = MD5(header || encrypted_payload), where during MD5 the
                          checksum slot is replaced by the 16-byte token.
                          For handshake (unknown=FFFFFFFF), filled with 0xFF.

  Payload encryption: AES-128-CBC, PKCS#7. Key/IV derived from token:
    key = MD5(token)
    iv  = MD5(key || token)
]]

local md5 = require "miio.md5"
local aes = require "miio.aes"

local M = {}

local MAGIC = 0x2131
local HELLO_HEADER = "\x21\x31\x00\x20" .. string.rep("\xFF", 28)  -- 32 bytes total

local function be_u16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function be_u32(n)
  return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end
local function rd_u16(s, off) return (s:byte(off) << 8) | s:byte(off + 1) end
local function rd_u32(s, off)
  return (s:byte(off) << 24) | (s:byte(off + 1) << 16) | (s:byte(off + 2) << 8) | s:byte(off + 3)
end

--- Derive AES key/IV from a 16-byte raw token.
function M.derive_key_iv(token_bytes)
  assert(#token_bytes == 16, "token must be 16 raw bytes")
  local key = md5.sum(token_bytes)
  local iv  = md5.sum(key .. token_bytes)
  return key, iv
end

--- Build the discovery (Hello) packet. 32 bytes, no payload.
function M.hello_packet()
  return HELLO_HEADER
end

--- Build a request packet.
-- @param token_bytes 16-byte raw token
-- @param device_id   uint32 from prior handshake
-- @param stamp       uint32 stamp to use (typically device_stamp + elapsed seconds)
-- @param json_body   JSON-RPC string (no trailing null)
function M.build(token_bytes, device_id, stamp, json_body)
  local key, iv = M.derive_key_iv(token_bytes)
  -- python-miio appends a NUL terminator to the JSON before encryption.
  local encrypted = aes.encrypt_cbc(key, iv, json_body .. "\0")
  local total_len = 32 + #encrypted
  local header_no_checksum =
    be_u16(MAGIC) ..
    be_u16(total_len) ..
    string.char(0, 0, 0, 0) ..
    be_u32(device_id) ..
    be_u32(stamp)
  -- MD5 input: header with checksum slot replaced by token, then encrypted payload.
  local checksum = md5.sum(header_no_checksum .. token_bytes .. encrypted)
  return header_no_checksum .. checksum .. encrypted
end

--- Parse a response packet and return (device_id, stamp, json_body | nil, err).
-- @param token_bytes 16-byte raw token
-- @param raw         raw response bytes from UDP socket
function M.parse(token_bytes, raw)
  if #raw < 32 then return nil, nil, nil, "short packet: " .. #raw end
  local magic = rd_u16(raw, 1)
  if magic ~= MAGIC then return nil, nil, nil, "bad magic " .. magic end
  local length = rd_u16(raw, 3)
  if length ~= #raw then
    return nil, nil, nil, string.format("length mismatch hdr=%d got=%d", length, #raw)
  end
  local device_id = rd_u32(raw, 9)
  local stamp = rd_u32(raw, 13)

  if #raw == 32 then
    -- handshake reply: no payload
    return device_id, stamp, nil, nil
  end

  local encrypted = raw:sub(33)
  local key, iv = M.derive_key_iv(token_bytes)
  local ok, plaintext = pcall(aes.decrypt_cbc, key, iv, encrypted)
  if not ok then return device_id, stamp, nil, "decrypt error: " .. tostring(plaintext) end
  if plaintext == nil then return device_id, stamp, nil, "padding error" end
  -- Strip trailing NUL if present (Xiaomi appends one before encryption).
  plaintext = plaintext:gsub("%z+$", "")
  return device_id, stamp, plaintext, nil
end

return M
