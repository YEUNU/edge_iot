-- Explicit opt-in integration fixture. Not a physical Xiaomi device.
-- Usage: lua tests/miio_hub_emulator.lua . <hub-ip> <expose|hidden>
-- Listens for at most 10 minutes and accepts packets only from that hub.
local root, hub, mode = ...
assert(root and hub and (mode == "expose" or mode == "hidden"), "specify repo, hub IP and expose/hidden")
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local socket = require "socket"
local packet = require "miio.packet"
local json = require "dkjson"
local token = string.rep("\x42", 16) -- public fixture key, never a household token
local did = 2130706001
local props = { ["2:1"] = false, ["6:8"] = 25, ["2:3"] = false,
  ["2:5"] = 90, ["2:7"] = 1, ["2:10"] = 0, ["3:1"] = false,
  ["4:3"] = 0, ["5:1"] = false, ["7:1"] = 50, ["7:7"] = 25 }
local s = assert(socket.udp())
assert(s:setsockname("0.0.0.0", 54321))
s:settimeout(0.5)
local deadline = socket.gettime() + 600
print("EMULATOR_READY did=" .. did .. " mode=" .. mode);io.stdout:flush()
while socket.gettime() < deadline do
  local raw, ip, port = s:receivefrom()
  if raw and ip == hub then
    local stamp = os.time()
    if raw == packet.hello_packet() then
      local tail = mode == "expose" and token or string.rep("\255", 16)
      s:sendto(string.pack(">I2I2I4I4I4",0x2131,32,0,did,stamp) .. tail, ip, port)
      print("HELLO_REPLY " .. mode)
    else
      local _, _, body, err = packet.parse(token, raw)
      if not err and body then
        local req = json.decode(body)
        if req then
          local result = {}
          if req.method == "miIO.info" then
            result = {model="zhimi.fan.za5", mac="02:00:7F:00:00:51",fw_ver="fixture"}
          elseif req.method == "get_properties" or req.method == "set_properties" then
            for _, p in ipairs(req.params or {}) do
              local key = tostring(p.siid) .. ":" .. tostring(p.piid)
              if req.method == "set_properties" and props[key] ~= nil then
                props[key] = p.value
                print("SET " .. key .. "=" .. tostring(p.value))
              end
              result[#result+1] = {did=p.did,siid=p.siid,piid=p.piid,
                code=props[key] ~= nil and 0 or -4001,value=props[key]}
            end
          end
          s:sendto(packet.build(token,did,stamp,json.encode({id=req.id,result=result})),ip,port)
          print("RPC " .. req.method)
        end
      end
    end
    io.stdout:flush()
  end
end
s:close()
