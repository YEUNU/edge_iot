-- Host-side production discovery test with actual appliance authentication.
-- Reads existing preferences from stdin; never prints/stores the token.
-- Only the test's in-memory device record uses a deliberately stale address.
local root = (...) or "."
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local json = require "dkjson"
local p = assert(json.decode(io.read("*a")))
p = p.values or p
local function value(v) return type(v)=="table" and v.value or v end
local ip, token = value(p.deviceIp), value(p.deviceToken)
local Client = require "miio.client"
local client = assert(Client.new{ip=ip,token=token,timeout_s=3})
local did = assert(client:handshake())
local info = assert(client:miio_info())
assert(type(info)=="table" and info.model, "encrypted model read failed")
package.preload.log = function() return {info=print,warn=print,error=print} end
local flow = require "discovery"
local fields = {local_connection={ip="192.0.2.1",did=did,token=token,model=info.model}}
local device = {model=info.model,device_network_id="ip-recovery-test",preferences={deviceIp="192.0.2.1",deviceToken=token}}
function device:get_field(k) return fields[k] end
function device:set_field(k,v) fields[k]=v end
local callback = false
flow.on_connected=function() callback=true end
local driver={datastore={}}
function driver:get_devices() return {device} end
function driver:try_create_device() error("IP recovery must not create duplicate devices") end
flow.scan(driver)
assert(callback and fields.local_connection.ip==ip, "recovery failed or broadcast reply absent")
print("physical_authenticated_ip_recovery=true")
print("household_device_modified=false")
print("SCOPE=actual broadcast and encrypted RPC; stale IP exists only in host test memory")
