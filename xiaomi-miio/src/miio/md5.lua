--[[
  Pure-Lua MD5 implementation. Requires Lua 5.3+ native bitwise operators.
  Output: 16 raw bytes (binary string). MD5.hex() returns lowercase hex.
  Reference: RFC 1321.
]]

local md5 = {}

local S = {
  7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
  5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
  4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
  6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}

local K = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local MASK = 0xFFFFFFFF

local function lrot(x, n)
  x = x & MASK
  return ((x << n) | (x >> (32 - n))) & MASK
end

local function F(x, y, z) return ((x & y) | ((~x) & z)) & MASK end
local function G(x, y, z) return ((x & z) | (y & (~z))) & MASK end
local function H(x, y, z) return (x ~ y ~ z) & MASK end
local function I(x, y, z) return (y ~ (x | (~z))) & MASK end

local function transform(state, M)
  local a, b, c, d = state[1], state[2], state[3], state[4]
  for i = 1, 64 do
    local f, g
    if i <= 16 then
      f = F(b, c, d); g = i
    elseif i <= 32 then
      f = G(b, c, d); g = ((5 * (i - 1) + 1) % 16) + 1
    elseif i <= 48 then
      f = H(b, c, d); g = ((3 * (i - 1) + 5) % 16) + 1
    else
      f = I(b, c, d); g = ((7 * (i - 1)) % 16) + 1
    end
    local tmp = d
    d = c
    c = b
    b = (b + lrot((a + f + K[i] + M[g]) & MASK, S[i])) & MASK
    a = tmp
  end
  state[1] = (state[1] + a) & MASK
  state[2] = (state[2] + b) & MASK
  state[3] = (state[3] + c) & MASK
  state[4] = (state[4] + d) & MASK
end

--- Compute MD5 of a binary string. Returns 16-byte raw digest.
function md5.sum(msg)
  local state = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 }
  local orig_bit_len = #msg * 8

  local padded = msg .. "\x80"
  while (#padded % 64) ~= 56 do
    padded = padded .. "\0"
  end
  -- Append 64-bit little-endian length
  local tail = {}
  for i = 0, 7 do
    tail[#tail + 1] = string.char((orig_bit_len >> (i * 8)) & 0xFF)
  end
  padded = padded .. table.concat(tail)

  local nblocks = #padded // 64
  for blk = 0, nblocks - 1 do
    local M = {}
    for w = 0, 15 do
      local off = blk * 64 + w * 4 + 1
      local b1, b2, b3, b4 = padded:byte(off, off + 3)
      M[w + 1] = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
    end
    transform(state, M)
  end

  local out = {}
  for i = 1, 4 do
    local v = state[i]
    out[#out + 1] = string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)
  end
  return table.concat(out)
end

--- Hex-encoded MD5 digest (lowercase).
function md5.hex(msg)
  local raw = md5.sum(msg)
  local hex = {}
  for i = 1, #raw do
    hex[#hex + 1] = string.format("%02x", raw:byte(i))
  end
  return table.concat(hex)
end

return md5
