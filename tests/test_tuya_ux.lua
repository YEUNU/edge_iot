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

-- Delivery results must survive failures in events, presence updates and logs.
fields.active_profile=original;fields.candidate_profile=original
fields.setup_open=false;fields.setup_closed=true;fields.keys_open=false
local real_emit,real_online,real_offline,real_warn=d.emit_event,d.online,d.offline,d.log.warn
local function good_response()
 return {state={},supported_modes={'cool'},supported_fans={'auto'},supported_keys={}}
end
for _,failure in ipairs({'event','online','log'}) do
 local first=true;local before=#calls;d.is_online=false
 request_override=function()
  if first then first=false;h.switch.off(nil,d) end
  return good_response()
 end
 function d:emit_event(e)
  if failure=='event' or failure=='log' then error('event publishing failed') end
  return real_emit(self,e)
 end
 function d:online()
  if failure=='online' then error('presence publishing failed') end
  return real_online(self)
 end
 d.log.warn=function()if failure=='log' then error('logger failed') end end
 h.switch.on(nil,d)
 assert(#calls==before+2,'publishing failures must not block queued commands')
 assert(calls[before+1].changes.power==true and calls[before+2].changes.power==false,'delivery order must be preserved')
 assert(not fields.busy and #fields.requests==0,'worker must release after publishing failure')
 if failure~='online' then assert(d.is_online==true,'event failure must not reverse a successful LAN result') end
 d.emit_event=real_emit;d.online=real_online;d.log.warn=real_warn
 h.switch.on(nil,d)
 assert(#calls==before+3,'future commands must recover without replaying earlier IR')
end
print('Event, online-status and logger exceptions preserve delivery and queue progress')

for _,failure in ipairs({'unreachable','exception','offline'}) do
 local first=true;local before=#calls
 request_override=function()
  if first then
   first=false;h.switch.off(nil,d)
   if failure=='exception' then error('transport exception') end
   return nil,'unreachable'
  end
  return good_response()
 end
 if failure=='offline' then function d:offline()error('presence publishing failed')end end
 h.switch.on(nil,d)
 d.offline=real_offline
 assert(#calls==before+2 and d.is_online==true,'failed request must not block its queued successor')
 assert(not fields.busy and #fields.requests==0,'worker must release on all failure paths')
end
print('Transport and offline-status exceptions allow the next queued command')

local malformed={
 false,123,'invalid',{},
 {state=false,supported_modes={'cool'},supported_fans={'auto'}},
 {state={power='on'},supported_modes={'cool'},supported_fans={'auto'}},
 {state={target_temperature=0/0},supported_modes={'cool'},supported_fans={'auto'}},
 {state={target_temperature=math.huge},supported_modes={'cool'},supported_fans={'auto'}},
 {state={mode='invalid'},supported_modes={'cool'},supported_fans={'auto'}},
 {state={},supported_modes=false,supported_fans={'auto'}},
 {state={},supported_modes={'invalid'},supported_fans={'auto'}},
 {state={},supported_modes={named='cool'},supported_fans={'auto'}},
 {state={},supported_modes={'cool'},supported_fans={true}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},supported_keys=123},
 {state={},supported_modes={'cool'},supported_fans={'auto'},supported_keys={'power'}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},supported_keys={{id=false}}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},supported_keys={{id=''}}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},settings=false},
 {state={},supported_modes={'cool'},supported_fans={'auto'},settings={fan=123}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},settings={target_temperature=true}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},temperature=false},
 {state={},supported_modes={'cool'},supported_fans={'auto'},temperature={min=18,max=30,step=0}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},temperature={min=30,max=18,step=1}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},temperature={min=18,max=math.huge,step=1}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},temperature={min='18',max=30,step=1}},
 {state={},supported_modes={'cool'},supported_fans={'auto'},control_style='invalid'},
 {state={},supported_modes={'cool'},supported_fans={'auto'},settings_save_pending='true'},
}
for _,response in ipairs(malformed) do
 local first=true;local before=#calls
 request_override=function()
  if first then first=false;h.switch.off(nil,d);return response end
  return good_response()
 end
 h.switch.on(nil,d)
 assert(#calls==before+2,'malformed responses must not block or repeat requests')
 assert(not fields.busy and #fields.requests==0 and d.is_online==true,'next valid response must recover')
end
print(#malformed..' malformed response shapes reject safely and allow queue recovery')

request_override=function()local response=good_response();response.settings_save_pending=true;return response end
local before=#calls;local event_start=#events
h.switch.on(nil,d)
assert(#calls==before+1,'pending storage must not trigger another command')
local storage_warning=false
for i=event_start+1,#events do
 local e=events[i]
 if e.cap=='earthpanel38939.acLocalLink' and e.attr=='status' and e.value=='명령 전송 완료 · 설정 저장 대기' then storage_warning=true end
end
assert(storage_warning,'successful IR with pending storage needs a separate status')
request_override=function()return good_response()end
function d:emit_event()error('setup event failed')end
h.refresh.refresh(nil,d)
d.emit_event=real_emit
assert(#calls==before+2 and calls[#calls].changes==nil,'setup publishing failure must not prevent a health poll')
assert(not fields.busy and #fields.requests==0)
request_override=nil
print('Storage-pending status and polling survive UI errors without IR replay')

-- A LAN operation can yield while the user saves another model. Its old
-- command result cannot repaint that model, and the latest poll must survive.
local function reset_view()
 request_override=nil
 fields.active_profile=original;fields.candidate_profile=original
 fields.setup_open=false;fields.setup_closed=true;fields.keys_open=false
 fields.bridge_credentials={bridgeToken='valid',bridgeIp='192.168.1.49',bridgePort=8766}
 fields.pending_refresh=nil
 fields.published_events=nil
end
local function response_for(p,temperature,mode)
 return {profile_id=tostring(p.remoteIndex),state={},
  settings={mode=mode or 'cool',fan='auto',target_temperature=temperature},
  supported_modes={mode or 'cool'},supported_fans={'auto'},supported_keys={},
  temperature={min=16,max=30,step=1}}
end
local function no_old_state(start)
 for i=start+1,#events do
  local e=events[i]
  assert(not (e.cap=='switch' and e.attr=='switch' and e.value=='on'),'old power must not repaint a changed model')
  assert(not (e.cap=='airConditionerMode' and e.attr=='airConditionerMode' and e.value=='heat'),'old mode must not repaint a changed model')
  assert(not (e.cap=='thermostatCoolingSetpoint' and e.attr=='coolingSetpoint' and e.value.value==30),'old temperature must not repaint a changed model')
 end
end
reset_view()
local changed=false;before=#calls;event_start=#events
request_override=function(p,c)
 if not changed then
  changed=true
  link.configure(nil,d)
  library.setCandidate(nil,d,{args={candidate='1000048'}})
  library.setCandidate(nil,d,{args={candidate='1000047'}})
  library.applyCode(nil,d)
  local result=response_for(p,30,'heat');result.state={power=true,mode='heat',fan='auto',target_temperature=30}
  return result
 end
 assert(p.remoteIndex==1000047 and c==nil,'the latest saved model needs a health poll')
 return response_for(p,16)
end
h.switch.on(nil,d)
assert(fields.active_profile=='1000047' and #calls==before+2,'model changes must coalesce into the latest required poll')
assert(calls[before+1].changes.power==true and calls[before+2].changes==nil,'an old IR command must never be replayed')
assert(not fields.busy and #fields.requests==0 and fields.pending_refresh==nil)
no_old_state(event_start)
print('Saving another model during a LAN request drops old UI values and polls the latest model')

-- Leaving setup while a test is in flight must also preserve its return poll.
reset_view();link.configure(nil,d);library.setCandidate(nil,d,{args={candidate='1000047'}})
changed=false;before=#calls;event_start=#events
request_override=function(p,c)
 if not changed then
  changed=true;link.done(nil,d)
  local result=response_for(p,30,'heat');result.state={power=true,mode='heat',fan='auto',target_temperature=30}
  return result
 end
 assert(p.remoteIndex==tonumber(original) and c==nil,'cancelled testing must poll the saved model')
 return response_for(p,18)
end
h.switch.on(nil,d)
assert(#calls==before+2 and fields.active_profile==original and not fields.setup_open)
no_old_state(event_start)
assert(fields.setup_note~='명령을 보냈습니다 · 실제 작동 상태는 확인할 수 없습니다','an obsolete completion must not overwrite the new view note')
print('Cancelling an in-flight trial polls the saved model without publishing trial state')

-- Queued commands retain their arrival-time profile and connection. A later
-- refresh is satisfied by the final command only when its view also matches.
reset_view();changed=false;before=#calls;event_start=#events
request_override=function(p,c)
 if not changed then
  changed=true
  h.switch.off(nil,d)
  link.configure(nil,d)
  library.setCandidate(nil,d,{args={candidate='1000047'}})
  library.applyCode(nil,d)
  h.switch.on(nil,d)
  h.refresh.refresh(nil,d)
  local result=response_for(p,30,'heat');result.state={power=true,mode='heat',fan='auto',target_temperature=30}
  return result
 end
 if p.remoteIndex==tonumber(original) then
  assert(c.power==false,'queued old-model commands must retain their profile')
  return response_for(p,18)
 end
 assert(p.remoteIndex==1000047 and c.power==true,'new-model command must keep its place in the queue')
 return response_for(p,16)
end
h.switch.on(nil,d)
assert(#calls==before+3,'the last matching command must satisfy the coalesced poll')
no_old_state(event_start)
assert(not fields.busy and #fields.requests==0 and fields.pending_refresh==nil)
print('Queued commands preserve order and profile while the newest matching command satisfies refresh')

-- A mismatched bridge response cannot establish state. A queued command and
-- later poll can recover without replaying the already issued command.
reset_view();changed=false;before=#calls;event_start=#events
request_override=function(p,c)
 if not changed then
  changed=true;h.switch.off(nil,d)
  local result=response_for(p,30,'heat');result.profile_id='1000047'
  result.state={power=true,mode='heat',fan='auto',target_temperature=30}
  return result
 end
 assert(c.power==false)
 return response_for(p,18)
end
h.switch.on(nil,d)
assert(#calls==before+2 and d.is_online==true and not fields.busy)
no_old_state(event_start)
request_override=nil
print('Mismatched profile responses reject safely and preserve queued command recovery')

-- Profile changes can happen inside event publication too. Every later event
-- must recheck the model rather than relying on a previously cached decision.
reset_view();changed=false;before=#calls
request_override=function(p)
 local result=response_for(p,p.remoteIndex==1000047 and 16 or 30,p.remoteIndex==1000047 and 'cool' or 'heat')
 if p.remoteIndex~=1000047 then result.state={power=true,mode='heat',fan='auto',target_temperature=30} end
 return result
end
local changed_at
function d:emit_event(e)
 if not changed and e.cap=='earthpanel38939.acRemoteKeys' and e.attr=='supportedKeys' then
  changed=true
  link.configure(nil,d)
  library.setCandidate(nil,d,{args={candidate='1000047'}})
  library.applyCode(nil,d)
  changed_at=#events
 end
 return real_emit(self,e)
end
h.switch.on(nil,d)
d.emit_event=real_emit
assert(changed and #calls==before+2 and fields.active_profile=='1000047')
no_old_state(changed_at)
assert(not fields.busy and fields.pending_refresh==nil)
request_override=nil
print('Reentrant model changes during event publication stop later old-model events')

-- Remembered settings do not prove an absolute power state after restart,
-- model selection or an extra remote button. Keep the distinction visible.
reset_view()
local function connection_text()
 for i=#events,1,-1 do
  local e=events[i]
  if e.cap=='earthpanel38939.acLocalLink' and e.attr=='status' then return e.value end
 end
end
request_override=function(p)return response_for(p,18)end
h.refresh.refresh(nil,d)
assert(connection_text()=='전원 미확인 · 저장된 설정 기준','unknown state must be distinguished from remembered settings')
request_override=function(p)
 local result=response_for(p,18);result.state={power=true,mode='cool',fan='auto',target_temperature=18}
 return result
end
h.switch.on(nil,d)
assert(connection_text()=='리모컨 명령 기준','a transmitted absolute state should keep the normal command-based label')
fields.keys_open=true;fields.remote_key='extra'
request_override=function(p,c)
 local result=response_for(p,18);result.supported_keys={{id='extra'}}
 return result
end
raw.sendKey(nil,d)
assert(connection_text()=='버튼 전송 기준 · 실제 상태는 확인할 수 없습니다','remote-button view must keep its button transmission label')
raw.back(nil,d)
assert(connection_text()=='전원 미확인 · 저장된 설정 기준','returning after a button must not imply an established power state')
request_override=function(p)
 local result=response_for(p,18);result.control_style='buttons';result.supported_keys={{id='power'}}
 return result
end
h.refresh.refresh(nil,d)
assert(connection_text()=='버튼 전송 기준 · 실제 상태는 확인할 수 없습니다','button-only profile must retain its absolute-state warning')
request_override=nil
print('Unknown power and remembered settings are distinguished while button-view warnings stay intact')

reset_view();changed=false;before=#calls
request_override=function(p)
 if p.remoteIndex==tonumber(original) then return nil,'unreachable' end
 return response_for(p,16)
end
function d:emit_event(e)
 if not changed and e.cap=='earthpanel38939.acModelLibrary' and e.attr=='status'
   and e.value=='요청 실패 · 연결 또는 지원 조합을 확인하세요' then
  changed=true
  link.configure(nil,d)
  library.setCandidate(nil,d,{args={candidate='1000047'}})
  library.applyCode(nil,d)
  changed_at=#events
 end
 return real_emit(self,e)
end
h.switch.on(nil,d)
d.emit_event=real_emit
assert(changed and #calls==before+2 and d.is_online==true and fields.active_profile=='1000047')
for i=changed_at+1,#events do
 local e=events[i]
 assert(not (e.cap=='earthpanel38939.acLocalLink' and e.attr=='status' and e.value=='브리지 연결 확인 필요'),
  'failure publication must recheck the model after a note event reenters setup')
end
assert(not fields.busy and fields.pending_refresh==nil)
request_override=nil
print('Failure-note reentry cannot publish an old connection error in the new model view')

-- Poll the same absolute state through the actual daily profile capabilities.
-- Values are published once; every refresh still performs its LAN health read.
reset_view()
local supports_before=d.supports_capability
function d:supports_capability(cap)
 return cap.ID~='earthpanel38939.acModelLibrary' and cap.ID~='earthpanel38939.acRemoteKeys'
end
local stable=response_for({remoteIndex=tonumber(original)},24)
stable.state={power=true,mode='cool',fan='auto',target_temperature=24}
request_override=function(p)stable.profile_id=tostring(p.remoteIndex);return stable end
before=#calls;event_start=#events
h.refresh.refresh(nil,d)
assert(#events==event_start+12,'a new daily view must publish every state and capability value')
event_start=#events
for _=1,10 do h.refresh.refresh(nil,d) end
assert(#events==event_start and #calls==before+11,'unchanged polls must retain health reads without duplicate UI events')
print('Ten unchanged daily polls emit zero duplicate events and preserve all health reads')

-- Shared decoded arrays may be mutated by the next response. Cached values
-- must be independent so a genuinely changed supported-mode list is visible.
stable.supported_modes[2]='heat';event_start=#events
h.refresh.refresh(nil,d)
assert(#events==event_start+2,'changed mode lists must update both supported-mode capabilities')
event_start=#events;h.refresh.refresh(nil,d)
assert(#events==event_start,'the newly published list must also coalesce')

-- Reconnection, model changes and returning from extra buttons need a fresh
-- full publication even when the new view happens to contain the same values.
for _,change in ipairs({'connection','model','keys'}) do
 if change=='connection' then fields.bridge_credentials.bridgeIp='192.168.1.50'
 elseif change=='model' then fields.active_profile='1000047'
 else fields.keys_open=true;h.refresh.refresh(nil,d);fields.keys_open=false end
 event_start=#events;h.refresh.refresh(nil,d)
 assert(#events==event_start+12,'each changed connection or view must republish its values')
end
print('Copied arrays and connection/model/key-view changes retain complete publication')

-- A failed event is never marked as delivered. Retry that value on the next
-- poll without re-emitting values that were already published successfully.
stable.settings.target_temperature=25;stable.state.target_temperature=25
local failed_event=true;local failed_count=0
function d:emit_event(e)
 if e.cap=='thermostatCoolingSetpoint' and e.attr=='coolingSetpoint' and failed_event then
  failed_count=failed_count+1;failed_event=false;error('temporary event failure')
 end
 return real_emit(self,e)
end
h.refresh.refresh(nil,d);event_start=#events
h.refresh.refresh(nil,d)
assert(failed_count==1 and #events==event_start+1,'only the unpublished temperature event should be retried')
assert(events[#events].attr=='coolingSetpoint' and events[#events].value.value==25)
d.emit_event=real_emit

stable.settings_save_pending=true;failed_event=true;failed_count=0
function d:emit_event(e)
 if e.cap=='earthpanel38939.acLocalLink' and e.value=='명령 전송 완료 · 설정 저장 대기' and failed_event then
  failed_count=failed_count+1;failed_event=false;error('temporary status failure')
 end
 return real_emit(self,e)
end
h.refresh.refresh(nil,d);event_start=#events;h.refresh.refresh(nil,d)
assert(failed_count==1 and #events==event_start+1,'a failed pending-save status must be published again')
event_start=#events;h.refresh.refresh(nil,d)
assert(#events==event_start,'pending-save polls must not alternate between ordinary and pending status')
d.emit_event=real_emit;stable.settings_save_pending=false
print('Failed state/status events retry safely and stable pending-save status does not flicker')

-- Setup attachment remains asynchronous, and explicit repeated test commands
-- still publish completion feedback even when their resulting values match.
reset_view();local attached=false
function d:supports_capability(cap)
 if cap.ID=='earthpanel38939.acModelLibrary' then return attached end
 return true
end
link.configure(nil,d);attached=true;event_start=#events
h.refresh.refresh(nil,d)
assert(#events==event_start+4,'newly attached setup controls need brand, choices, candidate and note')
event_start=#events
for _=1,10 do h.refresh.refresh(nil,d) end
assert(#events==event_start,'unchanged setup polls must also avoid duplicate events')
event_start=#events;before=#calls
h.switch.on(nil,d);h.switch.on(nil,d)
assert(#calls==before+2 and #events==event_start+2,'each repeated test command must still send and publish completion feedback')
assert(events[#events].value=='반응 확인 후 저장')
print('Asynchronous setup attachment and repeated command completion feedback are preserved')

-- Selecting a now-unavailable key must not leave its label behind when the
-- next response restores the first available key from a cached earlier list.
reset_view();fields.keys_open=true;d.supports_capability=supports_before
request_override=function(p)
 local result=response_for(p,24);result.supported_keys={{id='first'},{id='second'}};return result
end
h.refresh.refresh(nil,d);raw.selectKey(nil,d,{args={key='unavailable'}})
event_start=#events;h.refresh.refresh(nil,d)
assert(fields.remote_key=='first' and #events==event_start+1,'poll must correct a previously selected unavailable key')
assert(events[#events].attr=='key' and events[#events].value=='first')
request_override=nil
print('Remote-key selection and correction share one successful-publication cache')

-- A button-only view can inherit a pending settings save from a previously
-- selected absolute-state profile. It must show one stable pending label and
-- restore its state warning once saving succeeds.
reset_view()
local button_pending=true
request_override=function(p)
 return {profile_id=tostring(p.remoteIndex),state={},settings={},control_style='buttons',
  supported_modes={},supported_fans={},supported_keys={{id='power'}},settings_save_pending=button_pending}
end
event_start=#events;h.refresh.refresh(nil,d)
local status_count=0
for i=event_start+1,#events do
 local e=events[i]
 if e.cap=='earthpanel38939.acLocalLink' then
  status_count=status_count+1
  assert(e.value=='명령 전송 완료 · 설정 저장 대기','pending save must take precedence over the button label')
 end
end
assert(status_count==1,'the pending button view must publish a single connection label')
event_start=#events
for _=1,10 do h.refresh.refresh(nil,d)end
assert(#events==event_start,'stable button/save-pending polls must not flicker or duplicate events')
button_pending=false;event_start=#events;h.refresh.refresh(nil,d)
assert(#events==event_start+1 and connection_text()=='버튼 전송 기준 · 실제 상태는 확인할 수 없습니다',
 'save recovery must restore the button transmission warning once')
request_override=nil
print('Button-only pending-save status stays stable and restores the warning after recovery')

-- An event can synchronously publish another value for the same attribute.
-- The outer event must not overwrite the newer cache, and a failed inner
-- event must leave that attribute eligible for repair on the next poll.
for _,inner in ipairs({'unavailable','second','failed'}) do
 reset_view();fields.keys_open=true;d.supports_capability=supports_before
 request_override=function(p)
  local result=response_for(p,24);result.supported_keys={{id='first'},{id='second'}};return result
 end
 h.refresh.refresh(nil,d);raw.selectKey(nil,d,{args={key='second'}})
 local injected=false
 function d:emit_event(e)
  if inner=='failed' and e.cap=='earthpanel38939.acRemoteKeys' and e.attr=='key' and e.value=='unavailable' then
   error('inner publication failed')
  end
  real_emit(self,e)
  if e.cap=='earthpanel38939.acRemoteKeys' and e.attr=='key' and e.value=='first' and not injected then
   injected=true
   local ok=pcall(raw.selectKey,nil,d,{args={key=inner=='failed' and 'unavailable' or inner}})
   assert(ok==(inner~='failed'))
  end
 end
 raw.selectKey(nil,d,{args={key='first'}});d.emit_event=real_emit
 event_start=#events;h.refresh.refresh(nil,d)
 assert(injected)
 if inner=='second' then
  assert(fields.remote_key=='second' and #events==event_start,'a successful newer valid selection must remain current')
  assert(events[#events].value=='second','reselecting the old cached value inside an in-flight event must publish it')
 else
  assert(fields.remote_key=='first' and #events==event_start+1,'the poll must repair an unavailable or unpublished nested selection')
  assert(events[#events].attr=='key' and events[#events].value=='first')
 end
end
request_override=nil
print('Nested same-attribute publications preserve the newest successful value and retry failed repairs')

-- Updating the available list can yield to a selection before the snapshot
-- publishes its own selected key. The visible value must match sendKey's field.
reset_view();fields.keys_open=true;d.supports_capability=supports_before
request_override=function(p)
 local result=response_for(p,24);result.supported_keys={{id='first'},{id='second'}};return result
end
local selected_during_list=false
function d:emit_event(e)
 real_emit(self,e)
 if e.cap=='earthpanel38939.acRemoteKeys' and e.attr=='supportedKeys' and not selected_during_list then
  selected_during_list=true
  raw.selectKey(nil,d,{args={key='second'}})
 end
end
h.refresh.refresh(nil,d);d.emit_event=real_emit
assert(selected_during_list and fields.remote_key=='second')
local visible_key
for _,e in ipairs(events) do
 if e.cap=='earthpanel38939.acRemoteKeys' and e.attr=='key' then visible_key=e.value end
end
assert(visible_key=='second','a list publication must preserve the newer visible user selection')
event_start=#events;h.refresh.refresh(nil,d)
assert(#events==event_start and fields.remote_key=='second','the next poll must keep the successful latest selection')
request_override=nil
print('Publishing remote-key choices preserves selections made while the list event is in flight')
