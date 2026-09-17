package.path='tuya-local/src/?.lua;'..package.path
local driver
local calls={}
local request_override
package.preload['st.driver']=function() return function(_,d) driver=d; return {run=function() end} end end
local caps=setmetatable({}, {__index=function(t,id)
 local c={ID=id,commands=setmetatable({}, {__index=function(_,k)return {NAME=k}end})}
 setmetatable(c,{__index=function(_,k)return function(v)return {cap=id,attr=k,value=v}end end});rawset(t,id,c);return c
end})
package.preload['st.capabilities']=function()return caps end
package.preload.client=function()return {
 valid=function(p)return p.bridgeToken=='valid'end,
 enroll=function()return {bridgeToken='valid',bridgeIp='192.168.1.49',bridgePort=8766}end,
 request=function(p,c)
  table.insert(calls,{profile=p.remoteIndex,changes=c})
  if request_override then return request_override(p,c) end
  return {state={},supported_modes={'cool'},supported_fans={'auto'}}
 end
}end
require 'init'
local fields={};local profile;local events={}
local d={preferences={},thread={call_on_schedule=function()return 1 end},log={warn=function()end}}
function d:get_field(k)return fields[k]end
function d:set_field(k,v)fields[k]=v end
function d:try_update_metadata(m)profile=m.profile end
function d:supports_capability()return true end
function d:emit_event(e)table.insert(events,e)end
function d:online()self.is_online=true end
function d:offline()self.is_online=false end
driver.lifecycle_handlers.init(nil,d)
assert(profile=='tuya-local-ac.connect.v1','unconfigured devices must show connection guidance')
d.preferences.bridgeToken='valid';driver.lifecycle_handlers.init(nil,d)
assert(profile=='tuya-local-ac.acTemp18To30.v1')
d.preferences.changeModel=true
driver.lifecycle_handlers.infoChanged(nil,d,nil,{old_st_store={preferences={changeModel=false}}})
assert(profile=='tuya-local-ac.setup.v1')
driver.capability_handlers['earthpanel38939.acModelLibrary'].applyCode(nil,d)
assert(profile=='tuya-local-ac.acTemp18To30.v1','saving must return to everyday controls')
driver.lifecycle_handlers.init(nil,d)
assert(profile=='tuya-local-ac.acTemp18To30.v1','restart must not reopen the setup screen')
d.preferences.changeModel=false
driver.lifecycle_handlers.infoChanged(nil,d,nil,{old_st_store={preferences={changeModel=true}}})
d.preferences.changeModel=true
driver.lifecycle_handlers.infoChanged(nil,d,nil,{old_st_store={preferences={changeModel=false}}})
assert(profile=='tuya-local-ac.setup.v1','setup must be reopenable')
print('UX lifecycle checks passed')

d.preferences={};fields.bridge_credentials=nil
local link=driver.capability_handlers['earthpanel38939.acLocalLink']
link.enroll(nil,d,{args={address='192.168.1.49',port=8766,ticket=string.rep('a',64)}})
assert(fields.bridge_credentials.bridgeToken=='valid','enrollment must save credentials')
link.done(nil,d)
driver.lifecycle_handlers.init(nil,d)
assert(profile=='tuya-local-ac.acTemp18To30.v1','stored credentials must reconnect without preferences')
link.showKeys(nil,d)
assert(profile=='tuya-local-ac.acTemp18To30.v1','no extra keys must not open an empty remote view')
print('Automatic enrollment and restart checks passed')

local library=driver.capability_handlers['earthpanel38939.acModelLibrary']
local starting=#calls
link.configure(nil,d)
library.setBrand(nil,d,{args={brand='Samsung'}})
for i=starting+1,#calls do assert(calls[i].changes==nil,'browsing may query capabilities but must not send IR') end
assert(fields.active_profile=='104800501','browsing must not save a different model')
local candidate=fields.candidate_profile
driver.capability_handlers.switch.on(nil,d)
assert(calls[#calls].profile==tonumber(candidate) and calls[#calls].changes.power==true)
assert(fields.active_profile=='104800501','test must not save candidate')
link.done(nil,d)
assert(calls[#calls].profile==104800501,'cancel must restore original profile')
request_override=function()return nil,'unreachable'end
driver.capability_handlers.refresh.refresh(nil,d)
assert(d.is_online==false,'connection failure must mark offline')
request_override=nil
driver.capability_handlers.refresh.refresh(nil,d)
assert(d.is_online==true,'successful poll must recover online')
request_override=function()return nil,'unsupported'end
driver.capability_handlers.switch.on(nil,d)
assert(d.is_online==true,'unsupported combination is not a connection failure')
local queued=false;local before=#calls
request_override=function()
 if not queued then
  queued=true
  driver.capability_handlers.switch.off(nil,d)
  driver.capability_handlers.refresh.refresh(nil,d)
 end
 return {state={},supported_modes={'cool'},supported_fans={'auto'}}
end
driver.capability_handlers.switch.on(nil,d)
assert(#calls==before+2,'queued commands must survive; busy poll must coalesce')
assert(calls[before+1].changes.power==true and calls[before+2].changes.power==false)
assert(not fields.busy and #fields.requests==0)
print('Candidate isolation, cancel, outage recovery, unsupported input and queue checks passed')
request_override=nil
local library_ready=false
function d:supports_capability(cap)
 if cap.ID=='earthpanel38939.acModelLibrary' then return library_ready end
 return true
end
link.configure(nil,d)
local event_count=#events
library_ready=true
driver.capability_handlers.refresh.refresh(nil,d)
local candidate_event=false
for i=event_count+1,#events do
 local e=events[i]
 if e.cap=='earthpanel38939.acModelLibrary' and e.attr=='candidate' then candidate_event=true end
end
assert(candidate_event,'setup values must recover after asynchronous profile attachment')
print('Asynchronous profile attachment regression passed')

local original=fields.active_profile
library.setBrand(nil,d,{args={brand='Samsung'}})
local trial=tonumber(fields.candidate_profile)
local h=driver.capability_handlers
h.thermostatCoolingSetpoint.setCoolingSetpoint(nil,d,{args={setpoint=24}})
assert(calls[#calls].profile==trial and calls[#calls].changes.target_temperature==24)
h.airConditionerMode.setAirConditionerMode(nil,d,{args={mode='heat'}})
assert(calls[#calls].profile==trial and calls[#calls].changes.mode=='heat')
h['earthpanel38939.acModeControl'].setMode(nil,d,{args={mode='cool'}})
assert(calls[#calls].profile==trial and calls[#calls].changes.mode=='cool','dropdown must control the trial model')
h.airConditionerFanMode.setFanMode(nil,d,{args={fanMode='high'}})
assert(calls[#calls].profile==trial and calls[#calls].changes.fan=='high')
h.refresh.refresh(nil,d)
assert(calls[#calls].profile==trial and calls[#calls].changes==nil,'poll must retain candidate controls')
assert(fields.active_profile==original,'full trial must not save candidate')
link.done(nil,d)
h.thermostatCoolingSetpoint.setCoolingSetpoint(nil,d,{args={setpoint=26}})
assert(calls[#calls].profile==tonumber(original),'normal controls must return to saved model')
h['earthpanel38939.acModeControl'].setMode(nil,d,{args={mode='dry'}})
assert(calls[#calls].profile==tonumber(original) and calls[#calls].changes.mode=='dry','daily dropdown must control the saved model')
print('Full temperature/mode/fan trial routing and cancellation passed')

-- Button-only remotes must not display invented absolute temperatures/power.
local cat=require 'catalog'
cat['999999']={brand='Winia',brands={'Winia'},style='buttons',name='Winia test buttons'}
request_override=function(p,c)
 return {state={},profile_id=tostring(p.remoteIndex),control_style='buttons',supported_keys={{id='power',name='전원 전환'}},supported_modes={},supported_fans={}}
end
link.configure(nil,d)
library.setBrand(nil,d,{args={brand='Winia'}})
library.setCandidate(nil,d,{args={candidate='999999'}})
assert(profile=='tuya-local-ac.setup-buttons.v1','button candidate needs button setup view')
local raw=driver.capability_handlers['earthpanel38939.acRemoteKeys']
local count=#calls
raw.selectKey(nil,d,{args={key='power'}})
assert(#calls==count,'selecting a remote button must not transmit')
raw.sendKey(nil,d)
assert(calls[#calls].profile==999999 and calls[#calls].changes.key=='power','send routes to candidate')
library.applyCode(nil,d)
assert(profile=='tuya-local-ac.buttons.v1','button remote must not show absolute controls')
link.showKeys(nil,d)
assert(profile=='tuya-local-ac.keys.v1')
raw.back(nil,d)
assert(profile=='tuya-local-ac.buttons.v1')
request_override=nil
print('Button-only selection, trial, save and back routing passed')
