-- Host CPU benchmark only; no sockets, appliance traffic or latency claims.
-- Usage: lua scripts/benchmark_miio.lua [source-root] [iterations]
-- Point source-root at an older checkout to compare the same workload.
local root, iterations = (arg[1] or "."), tonumber(arg[2] or "1000")
assert(iterations and iterations % 1 == 0 and iterations > 0, "iterations must be a positive integer")
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local aes, packet = require "miio.aes", require "miio.packet"
local key, iv = string.rep("\x01", 16), string.rep("\x02", 16)
local function time(operation)
  collectgarbage("collect")
  local started = os.clock()
  for _ = 1, iterations do operation() end
  return os.clock() - started
end
for _, size in ipairs({64, 128, 256, 512}) do
  local body = string.rep("a", size)
  local encrypted = aes.encrypt_cbc(key, iv, body)
  local elapsed = time(function() assert(aes.decrypt_cbc(key, iv, encrypted) == body) end)
  print(string.format("decrypt bytes=%d iterations=%d cpu_s=%.6f", size, iterations, elapsed))
end
local body = '{"id":1,"result":[{"did":"power","siid":2,"piid":1,"code":0,"value":true},{"did":"mode","siid":2,"piid":4,"code":0,"value":2}]}'
local raw = packet.build(key, 123, 456, body)
local elapsed = time(function()
  local did, stamp, plain, err = packet.parse(key, raw)
  assert(did == 123 and stamp == 456 and plain == body and not err)
end)
print(string.format("packet_parse encrypted_bytes=%d iterations=%d cpu_s=%.6f", #raw - 32, iterations, elapsed))
