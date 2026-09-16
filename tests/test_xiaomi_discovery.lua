local root = (...) or "."
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local discovery = require "miio.discover"
local packet = require "miio.packet"
local function hello(did, tail)
  return string.pack(">I2I2I4I4I4", 0x2131, 32, 0, did, 100) .. tail
end
assert(not discovery.parse(nil, "192.168.1.2", 54321))
assert(not discovery.parse(packet.hello_packet(), "192.168.1.2", 54321))
assert(not discovery.parse(hello(1, string.rep("a",16)), "192.168.1.2", 123))
assert(not discovery.parse(hello(1, string.rep("a",16)):sub(1,31), "192.168.1.2",54321))
for _, b in ipairs({"\0", "\255"}) do
 local d = assert(discovery.parse(hello(123,string.rep(b,16)),"192.168.1.2",54321))
 assert(d.did == 123 and d.token == nil)
end
local d = assert(discovery.parse(hello(123,string.rep("\1",16)),"192.168.1.2",54321))
assert(d.token == string.rep("01",16))
print("PASS: malformed discovery packets, sentinels, source port and candidate extraction")
package.preload.log = function() return {info=function() end, warn=function() end,error=function() end} end
local flow = require "discovery"
local Client = require "miio.client"
local token = string.rep("12",16)
local function fixture(info)
 local fields, created = {}, {}
 local device = {model="zhimi.fan.za5",device_network_id="old",preferences={deviceIp="192.168.1.2",deviceToken=token}}
 function device:get_field(k) return fields[k] end
 function device:set_field(k,v) fields[k]=v end
 local driver = {datastore={}}
 function driver:get_devices() return self.devices or {} end
 function driver:try_create_device(v) created[#created+1]=v;return true end
 Client.new = function() return {miio_info=function() return info end} end
 return driver,device,fields,created
end
local driver,device,fields,created = fixture({model="zhimi.fan.za5"})
discovery.scan=function() return {{ip="192.168.1.3",did=123,token=token}} end
flow.scan(driver,function() return true end)
assert(#created==1 and created[1].model=="zhimi.fan.za5")
assert(driver.datastore["discovered:xiaomi-miio-123"].token==token)
flow.scan(driver,function() return true end)
assert(#created==1, "pending creation must not duplicate")
device.device_network_id="xiaomi-miio-123"
flow.restore(driver,device)
assert(fields.local_connection.token==token and not driver.datastore["discovered:xiaomi-miio-123"])

driver,device,fields,created=fixture(nil)
flow.scan(driver,function() return true end)
assert(#created==0 and next(driver.datastore)==nil,"failed authentication must not enroll")

driver,device,fields,created=fixture({model="zhimi.fan.za5"})
driver.devices={device};fields.local_connection={ip="192.168.1.2",did=123,token=token}
flow.scan(driver,function() return true end)
assert(fields.local_connection.ip=="192.168.1.3" and #created==0)

driver,device,fields,created=fixture(nil)
driver.devices={device};fields.local_connection={ip="192.168.1.2",did=123,token=token}
flow.scan(driver,function() return true end)
assert(fields.local_connection.ip=="192.168.1.2","unauthenticated IP migration must fail")

driver,device,fields,created=fixture({model="zhimi.fan.za5"})
discovery.scan=function() return {{ip="192.168.1.3",did=123}} end
flow.scan(driver,function() return true end)
assert(#created==0,"hidden token must never create a connected device")
print("PASS: authenticated enrollment, pending deduplication, restoration, IP migration and hidden-token handling")
-- Model learned from encrypted info must override the setup profile's default fan.
driver,device,fields,created=fixture({model="zhimi.airp.cpa4"})
device.model="xiaomi.setup";driver.devices={device}
discovery.scan=function() return {{ip="192.168.1.2",did=123,token=token}} end
flow.scan(driver,function() return true end)
assert(fields.local_connection.model=="zhimi.airp.cpa4")
assert(#created==0)
print("PASS: authenticated model retained when adopting an existing setup record")
driver,device,fields,created=fixture({model="zhimi.fan.za5"})
driver.datastore["discovered:xiaomi-miio-123"]={token=token,created_at=os.time()-121}
flow.scan(driver,function() return true end)
assert(#created==1,"expired creation request must be retried")
print("PASS: asynchronous creation timeout permits retry")
local connection=require "connection"
local old=string.rep("ab",16)
local imported=string.rep("cd",16)
local manual=string.rep("ef",16)
local d={preferences={deviceToken=old},get_field=function()return {ip="192.168.1.3",token=imported,preference_token=old}end}
assert(connection.get(d).deviceToken==imported)
d.preferences.deviceToken=manual
assert(connection.get(d).deviceToken==manual)
print("PASS: imported token supersedes old preferences but respects a later manual change")
