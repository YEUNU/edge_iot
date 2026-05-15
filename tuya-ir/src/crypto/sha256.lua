--[[
  Pure-Lua SHA-256 (FIPS 180-4). Lua 5.3+ bitwise operators required.
  sha256.sum(msg) -> 32-byte raw digest
  sha256.hex(msg) -> lowercase hex
]]

local M = {}

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local MASK = 0xFFFFFFFF
local function ror(x, n) return ((x >> n) | (x << (32 - n))) & MASK end

local function compress(state, M16)
  local W = {}
  for i = 1, 16 do W[i] = M16[i] end
  for i = 17, 64 do
    local s0 = ror(W[i-15], 7) ~ ror(W[i-15], 18) ~ (W[i-15] >> 3)
    local s1 = ror(W[i-2], 17) ~ ror(W[i-2], 19) ~ (W[i-2] >> 10)
    W[i] = (W[i-16] + s0 + W[i-7] + s1) & MASK
  end
  local a,b,c,d,e,f,g,h = state[1],state[2],state[3],state[4],state[5],state[6],state[7],state[8]
  for i = 1, 64 do
    local S1 = ror(e, 6) ~ ror(e, 11) ~ ror(e, 25)
    local ch = (e & f) ~ ((~e) & g)
    local temp1 = (h + S1 + ch + K[i] + W[i]) & MASK
    local S0 = ror(a, 2) ~ ror(a, 13) ~ ror(a, 22)
    local mj = (a & b) ~ (a & c) ~ (b & c)
    local temp2 = (S0 + mj) & MASK
    h = g; g = f; f = e
    e = (d + temp1) & MASK
    d = c; c = b; b = a
    a = (temp1 + temp2) & MASK
  end
  state[1] = (state[1] + a) & MASK
  state[2] = (state[2] + b) & MASK
  state[3] = (state[3] + c) & MASK
  state[4] = (state[4] + d) & MASK
  state[5] = (state[5] + e) & MASK
  state[6] = (state[6] + f) & MASK
  state[7] = (state[7] + g) & MASK
  state[8] = (state[8] + h) & MASK
end

function M.sum(msg)
  local state = {
    0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19,
  }
  local bit_len = #msg * 8
  local padded = msg .. "\x80"
  while (#padded % 64) ~= 56 do padded = padded .. "\0" end
  -- 64-bit big-endian length
  local tail = {}
  for i = 7, 0, -1 do
    tail[#tail + 1] = string.char((bit_len >> (i * 8)) & 0xFF)
  end
  padded = padded .. table.concat(tail)

  for blk = 0, (#padded // 64) - 1 do
    local W = {}
    for w = 0, 15 do
      local off = blk * 64 + w * 4 + 1
      local b1, b2, b3, b4 = padded:byte(off, off + 3)
      W[w + 1] = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    end
    compress(state, W)
  end

  local out = {}
  for i = 1, 8 do
    local v = state[i]
    out[#out + 1] = string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
  end
  return table.concat(out)
end

function M.hex(msg)
  local raw = M.sum(msg)
  local hex = {}
  for i = 1, #raw do hex[#hex + 1] = string.format("%02x", raw:byte(i)) end
  return table.concat(hex)
end

return M
