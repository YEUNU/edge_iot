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
 Client.new = function() return {begin_session=function()return {dev_id=123}end,miio_info=function() return info end} end
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

-- Imported pending credentials must repair lost creation even when Hello hides the token.
driver,device,fields,created=fixture({model="zhimi.fan.za5"})
local pending_key="discovered:xiaomi-miio-123"
local attempted_token, scanned_addresses
driver.datastore[pending_key]={did=123,ip="192.168.1.2",token=token,model="zhimi.fan.za5",created_at=os.time()-121}
discovery.scan=function(addresses)scanned_addresses=addresses;return {{ip="192.168.1.3",did=123}} end
Client.new=function(opts)attempted_token=opts.token;return {begin_session=function()return {dev_id=123}end,miio_info=function()return {model="zhimi.fan.za5"}end}end
flow.scan(driver)
assert(attempted_token==token and #created==1)
assert(scanned_addresses[1]=="192.168.1.2" and driver.datastore[pending_key].ip=="192.168.1.3")
flow.scan(driver)
assert(#created==1,"a recent pending request must not be duplicated")
print("PASS: hidden-token pending retry, directed probing and deduplication")

-- Wrong tokens/DIDs and malformed results cannot replace imported credentials.
for _, failure in ipairs({"token", "did", "model", "malformed"}) do
 driver,device,fields,created=fixture(nil)
 local pending={did=123,ip="192.168.1.2",token=token,model="zhimi.fan.za5",created_at=os.time()-121}
 driver.datastore[pending_key]=pending
 Client.new=function()return {
  begin_session=function()return {dev_id=failure=="did" and 456 or 123}end,
  miio_info=function()
   if failure=="token" then return nil end
   if failure=="malformed" then return 42 end
   return {model=failure=="model" and "zhimi.airp.cpa4" or "zhimi.fan.za5"}
  end}end
 flow.scan(driver)
 assert(#created==0 and driver.datastore[pending_key]==pending,failure)
end
print("PASS: pending authentication failure and DID/model mismatch preserve credentials")

-- A rejected/raised creation request retains a hidden-token credential for retry.
for _, raised in ipairs({false,true}) do
 driver,device,fields,created=fixture({model="zhimi.fan.za5"})
 driver.datastore[pending_key]={did=123,token=token,created_at=0}
 local requests=0
 driver.try_create_device=function()requests=requests+1;if raised then error("creation failure")end return false end
 flow.scan(driver)
 assert(requests==1 and driver.datastore[pending_key].token==token and driver.datastore[pending_key].created_at==0)
 driver.try_create_device=function()requests=requests+1;return true end
 flow.scan(driver)
 assert(requests==2 and driver.datastore[pending_key].created_at>0)
end
print("PASS: creation rejection and exception preserve credentials for retry")

-- A fresh Hello token can recover a stale saved/pending token, but only after authentication.
driver,device,fields,created=fixture(nil)
driver.datastore[pending_key]={did=123,token=old,created_at=0}
local tried={}
discovery.scan=function()return {{ip="192.168.1.3",did=123,token=token}}end
Client.new=function(opts)tried[#tried+1]=opts.token;return {
 begin_session=function()return {dev_id=123}end,
 miio_info=function()return opts.token==token and {model="zhimi.fan.za5"} or nil end}end
flow.scan(driver)
assert(#tried==2 and tried[1]==old and tried[2]==token and #created==1)
assert(driver.datastore[pending_key].token==token)
print("PASS: stale pending token falls back to authenticated Hello candidate")

-- One bad device cannot suppress later scan results or leave the scan lock held.
driver,device,fields,created=fixture({model="zhimi.fan.za5"})
discovery.scan=function()return {false,42,{ip="bad",did=123},{ip="192.168.1.3",did=123,token=token}}end
flow.scan(driver)
assert(#created==1 and driver.xiaomi_scan_running==false)
print("PASS: malformed discovery records do not interrupt valid devices")

-- A reused address cannot remap a known DID even when its saved fields are absent.
driver,device,fields,created=fixture({model="zhimi.fan.za5"})
device.device_network_id="xiaomi-miio-456";driver.devices={device}
discovery.scan=function()return {{ip="192.168.1.2",did=123,token=token}}end
flow.scan(driver)
assert(#created==1 and not fields.local_connection)
print("PASS: network ID identity prevents same-IP reassignment")

-- Failed attachment is retried on the next authenticated scan, not silently stranded.
driver,device,fields,created=fixture({model="zhimi.fan.za5"})
driver.devices={device};fields.local_connection={did=123,ip="192.168.1.2",token=token,model="zhimi.fan.za5"}
local callbacks=0
flow.on_connected=function()callbacks=callbacks+1;if callbacks==1 then error("attach failure")end end
discovery.scan=function()return {{ip="192.168.1.3",did=123}}end
flow.scan(driver)
assert(fields.xiaomi_attach_pending and callbacks==1)
flow.scan(driver)
assert(not fields.xiaomi_attach_pending and callbacks==2)
flow.on_connected=nil
print("PASS: attachment exception is retried after saved connection migration")

-- A poisoned pending timestamp cannot suppress retries forever.
for _, timestamp in ipairs({0/0,math.huge,os.time()+1000,"bad"}) do
 driver,device,fields,created=fixture({model="zhimi.fan.za5"})
 driver.datastore[pending_key]={did=123,token=token,created_at=timestamp}
 flow.scan(driver)
 assert(#created==1)
end
print("PASS: invalid and future pending timestamps permit authenticated retry")

-- Setup creation is asynchronous too: repeated discovery must not create duplicates.
discovery.scan=function()return {}end
local setup_requests=0
local setup_driver={get_devices=function()return {}end,try_create_device=function()setup_requests=setup_requests+1;return true end}
flow.handle(setup_driver)
flow.handle(setup_driver)
assert(setup_requests==1)
setup_driver.xiaomi_setup_create_at=os.time()-121
flow.handle(setup_driver)
assert(setup_requests==2)
local failed_driver={get_devices=function()return {}end,try_create_device=function()error("create failure")end}
flow.handle(failed_driver)
assert(not failed_driver.xiaomi_setup_create_at)
print("PASS: pending setup creation deduplicates, retries and clears failed guard")

-- Fresh pending creation keeps its age but must refresh authenticated DHCP/token changes.
driver,device,fields,created=fixture(nil)
local prior_created=os.time()-5
driver.datastore[pending_key]={did=123,ip="192.168.1.2",token=old,model="zhimi.fan.za5",created_at=prior_created}
discovery.scan=function()return {{ip="192.168.1.3",did=123,token=token}}end
Client.new=function(opts)return {begin_session=function()return {dev_id=123}end,
 miio_info=function()return opts.token==token and {model="zhimi.fan.za5"} or nil end}end
flow.scan(driver)
assert(#created==0)
local migrated=driver.datastore[pending_key]
assert(migrated.created_at==prior_created and migrated.ip=="192.168.1.3" and migrated.token==token)
device.device_network_id="xiaomi-miio-123"
flow.restore(driver,device)
assert(fields.local_connection.ip=="192.168.1.3" and fields.local_connection.token==token)
print("PASS: fresh pending creation preserves age while authenticated credentials migrate")

-- A driver restart must not duplicate the setup request while it is still pending.
local persisted={}
setup_requests=0
local function restarting_driver()return {datastore=persisted,get_devices=function()return {}end,
 try_create_device=function()setup_requests=setup_requests+1;return true end}end
discovery.scan=function()return {}end
flow.handle(restarting_driver())
flow.handle(restarting_driver())
assert(setup_requests==1)
persisted.xiaomi_setup_create_at=os.time()-121
flow.handle(restarting_driver())
assert(setup_requests==2)
print("PASS: pending setup request survives driver restart without duplicate creation")

-- A slow discovery response cannot roll back a concurrent credential import.
for _, change in ipairs({"connection", "preferences", "pending"}) do
 driver,device,fields,created=fixture({model="zhimi.fan.za5"})
 device.preferences.deviceToken=old
 local original={ip="192.168.1.2",did=123,token=old,model="zhimi.fan.za5"}
 if change=="pending" then
  driver.datastore[pending_key]=original
 else
  driver.devices={device};fields.local_connection=original
 end
 discovery.scan=function()return {{ip="192.168.1.3",did=123,token=old}}end
 Client.new=function()return {begin_session=function()return {dev_id=123}end,
  miio_info=function()coroutine.yield();return {model="zhimi.fan.za5"}end}end
 local scan=coroutine.create(function()flow.scan(driver)end)
 assert(coroutine.resume(scan) and driver.xiaomi_scan_running)
 local updated={ip="192.168.1.4",did=123,token=token,model="zhimi.fan.za5",created_at=os.time()}
 if change=="pending" then driver.datastore[pending_key]=updated
 elseif change=="connection" then require("connection").save(device,updated)
 else device.preferences.deviceToken=token end
 assert(coroutine.resume(scan))
 assert(not driver.xiaomi_scan_running and #created==0)
 if change=="pending" then assert(driver.datastore[pending_key]==updated)
 elseif change=="connection" then assert(fields.local_connection==updated)
 else assert(fields.local_connection==original and require("connection").get(device).deviceToken==token)end
end
print("PASS: slow discovery preserves concurrent imported, manual and pending credentials")
