local root = (...) or "."
package.path = root .. "/xiaomi-miio/src/?.lua;" .. package.path
local real_json = require "dkjson"
local packet = require "miio.packet"
local clock, state, socket_count = 100, nil, 0
local marker = real_json.encode("fixture bundle response")
local ticket, key = string.rep("ab",16), string.rep(string.char(0xab),16)
package.preload["st.json"] = function() return {
  encode=real_json.encode,
  decode=function(value)if value==marker then return state.bundle end return real_json.decode(value)end,
}end
package.preload["cosock.socket"] = function()return {
 gettime=function()return clock end,
 tcp=function()
  socket_count=socket_count+1
  if state.socket_failure then return nil,"socket unavailable" end
  local number, line, request_path, response = socket_count, 0, nil, nil
  if number==2 then state.ack_attempted=true end
  return {
   settimeout=function(_,timeout)assert(timeout>0 and timeout<=10);state.timeouts[#state.timeouts+1]=timeout end,
   connect=function()if number==2 and state.ack_mode=="timeout" then return nil,"timeout" end return true end,
   close=function()end,
   send=function(_,request,offset)
    request_path=request:match("^POST (%S+)")
    if request_path=="/ack" and not state.ack then
     local raw=request:match("\r\n\r\n(.*)$")
     local _,_,payload=packet.parse(key,raw)
     state.ack=real_json.decode(payload)
     state.events[#state.events+1]="ack"
    end
    if state.partial_send and offset==1 then return nil,"timeout",7 end
    return #request
   end,
   receive=function(_,format)
    line=line+1
    if line==1 then return number==2 and state.ack_mode=="rejected" and "HTTP/1.1 403 Forbidden" or "HTTP/1.1 200 OK" end
    if line==2 then
     local plaintext=request_path=="/bundle" and marker or real_json.encode({ok=state.ack_mode~="false"})
     response=packet.build(key,1,1,plaintext)
     return "Content-Length: "..#response
    end
    if line==3 then return "" end
    if request_path=="/bundle" then clock=clock+(state.bundle_delay or 0) end
    return response
   end,
  }
 end,
}end
package.preload.log = function()return {info=function()end,warn=function()end,error=function()end}end
package.preload["miio.client"] = function()return {
 new=function(opts)
  state.auth_calls=state.auth_calls+1
  assert(opts.deadline and opts.deadline<=210,"authentication must reserve ACK time")
  local appliance=(state.appliances or {})[opts.ip] or {did=123,model="zhimi.fan.za5"}
  local function advance(delay)
   clock=math.min(clock+(delay or 0),opts.deadline)
   return clock<opts.deadline
  end
  return {
   begin_session=function()
    if appliance.raise then error("simulated malformed appliance response")end
    if not advance(appliance.hello_delay) or appliance.no_session then return nil end
    return {dev_id=appliance.did}
   end,
   miio_info=function(_,session)
    assert(session.dev_id==appliance.did)
    if not advance(appliance.info_delay) then return nil end
    return appliance.info or {model=appliance.model}
   end,
  }
 end,
}end
local discovery={on_connected=function(_,device)
 state.events[#state.events+1]="attach:"..device.device_network_id
 assert(state.ack_attempted,"device refresh must happen after ACK attempt")
 if state.attach_failure==device.device_network_id then error("simulated attachment failure")end
end}
package.preload.discovery=function()return discovery end
local enrollment=require "enrollment"
local function record(did,ip,model)
 return {did=did or 123,ip=ip or "192.168.1.2",token=ticket,model=model or "zhimi.fan.za5"}
end
local function device(did,ip,model,dni)
 local fields={}
 if did then fields.local_connection=record(did,ip,model)end
 local value={model=model or "zhimi.fan.za5",device_network_id=dni or "xiaomi-miio-"..tostring(did),preferences={deviceIp=ip}}
 function value:get_field(k)return fields[k]end
 function value:set_field(k,v)fields[k]=v end
 value.fields=fields
 return value
end
local function run(options)
 state=options or {}
 clock,socket_count=100,0
 if state.bundle==nil then state.bundle={device_id="setup",devices={record()},expires_in=120}end
 state.events,state.timeouts,state.created,state.statuses={}, {}, {}, {}
 state.auth_calls=0
 local driver={datastore=state.datastore or {},get_devices=function()return state.existing or {}end}
 function driver:try_create_device(value)
  state.created[#state.created+1]=value
  if state.creation_error then error("simulated creation failure")end
  return not state.creation_rejected
 end
 local args=state.args_set and state.args or {address="192.168.1.50",port=1234,ticket=ticket}
 if state.nil_args then args=nil end
 enrollment.handle(driver,{id="setup",model="xiaomi.setup"},args,function(message)
  if state.status_error then error("simulated event failure")end
  state.statuses[#state.statuses+1]=message
 end)
 assert(not driver.xiaomi_enrolling,"enrollment lock must always clear")
 state.driver=driver
 return state
end
local passed=0
local function test(name,fn)fn();passed=passed+1;print("PASS: "..name)end
local function counters(result,updated,requested,failed)
 assert(result.ack and result.ack.result.updated==updated and result.ack.result.requested==requested and result.ack.result.failed==failed)
end

test("same-IP different-DID appliances preserve existing identity",function()
 local old=device(456,"192.168.1.2")
 local result=run{existing={old}}
 assert(old.fields.local_connection.did==456 and #result.created==1)
 counters(result,0,1,0)
end)
test("network ID prevents remapping even before fields are restored",function()
 local old=device(nil,"192.168.1.2",nil,"xiaomi-miio-456")
 local result=run{existing={old}}
 assert(not old.fields.local_connection and #result.created==1)
end)
test("DID match takes priority over an earlier unconfigured same-IP record",function()
 local fallback=device(nil,"192.168.1.2",nil,"manual")
 local actual=device(123,"192.168.1.3")
 local result=run{existing={fallback,actual}}
 assert(not fallback.fields.local_connection and actual.fields.local_connection.ip=="192.168.1.2")
 counters(result,1,0,0)
 assert(result.events[1]=="ack" and result.events[2]=="attach:xiaomi-miio-123")
end)
test("manual devices without identity can adopt an authenticated DID",function()
 local manual=device(nil,"192.168.1.2",nil,"manual")
 counters(run{existing={manual}},1,0,0)
 assert(manual.fields.local_connection.did==123)
end)
test("matching DID with conflicting physical model is rejected",function()
 local old=device(123,"192.168.1.2","zhimi.airp.cpa4")
 local result=run{existing={old}}
 counters(result,0,0,1)
 assert(old.fields.local_connection.model=="zhimi.airp.cpa4")
end)
test("malformed records count as failures without suppressing valid records",function()
 local bad={false,42,"record",{},record(0),record(0/0),record(1.5),record(0xffffffff),record(123,"bad"),record(123,nil,"unknown")}
 local invalid_token=record();invalid_token.token="bad";bad[#bad+1]=invalid_token
 bad[#bad+1]=record(123)
 -- Invalid DID=123 records consume no identity: only valid records participate in deduplication.
 local result=run{bundle={device_id="setup",devices=bad,expires_in=120}}
 counters(result,0,1,#bad-1)
end)
test("scalar and oversized or sparse bundle shapes are rejected",function()
 local large={};for i=1,21 do large[i]=record(i)end
 local bundles={false,42,"bundle",{device_id="other",devices={record()}},{device_id="setup",devices=false},
  {device_id="setup",devices=large},{device_id="setup",devices={[2]=record()}},{device_id="setup",devices={unexpected=record()}}}
 for _,bundle in ipairs(bundles)do
  local result=run{bundle=bundle}
  assert(not result.ack and #result.created==0 and result.statuses[#result.statuses]:match("연결 실패"))
 end
end)
test("duplicate DID is imported once and accounted as a failure",function()
 counters(run{bundle={device_id="setup",devices={record(),record()},expires_in=120}},0,1,1)
end)
test("wrong handshake DID and wrong encrypted model cannot enroll",function()
 for _,appliance in ipairs({{did=456,model="zhimi.fan.za5"},{did=123,model="zhimi.airp.cpa4"},{did=123,info=42},{no_session=true},{raise=true}})do
  counters(run{appliances={["192.168.1.2"]=appliance}},0,0,1)
 end
end)
test("creation rejection or exception preserves credentials for later retry",function()
 for _,options in ipairs({{creation_rejected=true},{creation_error=true}})do
  local result=run(options);counters(result,0,0,1)
  local pending=result.driver.datastore["discovered:xiaomi-miio-123"]
  assert(pending.token==ticket and pending.created_at==0)
 end
end)
test("repeated import updates pending credentials without duplicate creation",function()
 local pending={did=123,token="old",created_at=os.time()-5}
 local result=run{datastore={["discovered:xiaomi-miio-123"]=pending}}
 counters(result,0,1,0)
 assert(#result.created==0 and result.driver.datastore["discovered:xiaomi-miio-123"].created_at==pending.created_at)
 assert(result.driver.datastore["discovered:xiaomi-miio-123"].token==ticket)
end)
test("expired or invalid pending timestamps trigger a fresh creation request",function()
 for _,timestamp in ipairs({os.time()-121,os.time()+1000,0/0,math.huge,"bad"})do
  local result=run{datastore={["discovered:xiaomi-miio-123"]={created_at=timestamp}}}
  counters(result,0,1,0);assert(#result.created==1)
 end
end)
test("ACK timeout rejection or false result is never displayed as success",function()
 for _,mode in ipairs({"timeout","rejected","false"})do
  local old=device(123,"192.168.1.2")
  local result=run{existing={old},ack_mode=mode}
  assert(result.statuses[#result.statuses]:match("완료 확인 실패"),mode)
  assert(old.fields.local_connection.did==123 and not old.fields.xiaomi_attach_pending)
 end
end)
test("per-device failures still ACK accurate partial success",function()
 local other=record(456,"192.168.1.3")
 counters(run{bundle={device_id="setup",devices={record(),other},expires_in=120},appliances={["192.168.1.3"]={no_session=true}}},0,1,1)
end)
test("one attachment exception does not suppress other updated devices",function()
 local first,second=device(123,"192.168.1.2"),device(456,"192.168.1.3")
 local result=run{existing={first,second},bundle={device_id="setup",devices={record(),record(456,"192.168.1.3")},expires_in=120},
  appliances={["192.168.1.3"]={did=456,model="zhimi.fan.za5"}},attach_failure="xiaomi-miio-123"}
 counters(result,2,0,0)
 assert(first.fields.xiaomi_attach_pending and not second.fields.xiaomi_attach_pending and #result.events==3)
end)
test("invalid expired and nonfinite transfer lifetimes cannot authenticate",function()
 for _,ttl in ipairs({0,-1,0/0,math.huge,121,"120",false})do
  local result=run{bundle={device_id="setup",devices={record()},expires_in=ttl}}
  assert(not result.ack and result.auth_calls==0 and #result.created==0)
 end
end)
test("short remaining lifetime reserves ACK time and rejects work",function()
 local result=run{bundle={device_id="setup",devices={record()},expires_in=5}}
 counters(result,0,0,1);assert(result.auth_calls==0)
end)
test("authentication expiration counts remaining devices as failed and still ACKs",function()
 local result=run{bundle={device_id="setup",devices={record(),record(456,"192.168.1.3")},expires_in=30},
  appliances={["192.168.1.2"]={did=123,hello_delay=15,info_delay=15}}}
 counters(result,0,0,2);assert(result.auth_calls==1 and clock==120)
end)
test("bundle transit cannot extend the helper lifetime",function()
 local result=run{bundle={device_id="setup",devices={record()},expires_in=20},bundle_delay=15}
 counters(result,0,0,1);assert(result.auth_calls==0)
end)
test("older helper lifetime omission remains compatible",function()
 counters(run{bundle={device_id="setup",devices={record()}}},0,1,0)
end)
test("partial TCP send is completed before consuming response",function()
 counters(run{partial_send=true},0,1,0)
end)
test("nil scalar and invalid command arguments cannot start enrollment",function()
 local options={{nil_args=true},{args_set=true,args=42},{args_set=true,args={}},
  {args_set=true,args={address="bad",port=1234,ticket=ticket}},
  {args_set=true,args={address="192.168.1.50",port=0/0,ticket=ticket}},
  {args_set=true,args={address="192.168.1.50",port=1.5,ticket=ticket}},
  {args_set=true,args={address="192.168.1.50",port=65536,ticket=ticket}}}
 for _,value in ipairs(options)do local result=run(value);assert(socket_count==0 and result.statuses[1]=="연결 요청 오류")end
end)
test("socket creation and status emission errors do not leave lock held",function()
 local result=run{socket_failure=true};assert(result.statuses[#result.statuses]:match("연결 실패"))
 counters(run{status_error=true},0,1,0)
end)
test("integer-valued float DID uses canonical stable network ID",function()
 local result=run{bundle={device_id="setup",devices={record(123.0)},expires_in=120}}
 assert(result.created[1].device_network_id=="xiaomi-miio-123")
end)
print(passed.." enrollment edge-case tests passed")
