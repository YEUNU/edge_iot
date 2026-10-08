local Driver = require 'st.driver'
local caps = require 'st.capabilities'
local Client = require 'client'
local catalog = require 'catalog'
local temperatures = require 'temperature_profiles'
local library = caps['earthpanel38939.acModelLibrary']
local connection = caps['earthpanel38939.acLocalLink']
local remote_keys = caps['earthpanel38939.acRemoteKeys']
local mode_control = caps['earthpanel38939.acModeControl']
local cached_emit
local function connection_note(device,text)
  if device:supports_capability(connection) then
    cached_emit(device,connection.ID..'.status',text,function() return connection.status(text) end)
  end
end
local function library_event(device,event,key,value)
  if device:supports_capability(library) then
    if key then cached_emit(device,library.ID..'.'..key,value,function() return event end)
    else device:emit_event(event) end
  end
end
local function note(device,text,cached)
  if device:get_field('setup_note')~=text then device:set_field('setup_note',text) end
  library_event(device,library.status(text,{state_change=true}),cached and 'status' or nil,text)
end
local function credentials(device)
  return device:get_field('bridge_credentials') or device.preferences
end
local function in_setup(device)
  return device:get_field('setup_open') or (device.preferences.changeModel and not device:get_field('setup_closed'))
end
local function update_view(device)
  -- Profile attachment is asynchronous. A newly attached view needs its first
  -- complete publication even when its values match the preceding view.
  device:set_field('published_events',nil)
  local setup=in_setup(device)
  local active=catalog[tostring(device:get_field('active_profile') or 104800501)] or {}
  local candidate=catalog[tostring(device:get_field('candidate_profile') or 104800501)] or {}
  local profile=not Client.valid(credentials(device)) and 'tuya-local-ac.connect.v1'
    or (device:get_field('keys_open') and 'tuya-local-ac.keys.v1')
    or (setup and (candidate.style=='buttons' and 'tuya-local-ac.setup-buttons.v1' or 'tuya-local-ac.setup.v1'))
    or (active.style=='buttons' and 'tuya-local-ac.buttons.v1')
    or ( ('tuya-local-ac.'..(temperatures.by_id[tostring(device:get_field('active_profile') or 104800501)] or 'acTemp18To30')..'.v1'))
  device:try_update_metadata({profile=profile})
end
local function selected(device)
  return tostring(device:get_field('active_profile') or device.preferences.remoteIndex or 104800501)
end
local function matches_brand(item, brand)
  if item.brand==brand then return true end
  for _,name in ipairs(item.brands or {}) do if name==brand then return true end end
  return false
end
local function show_candidate(device, id)
  if not catalog[id] then
    for key,p in pairs(catalog) do if p.name==id then id=key;break end end
  end
  local item=catalog[id]
  if not item then note(device,'등록되지 않은 코드셋'); return end
  if device:get_field('candidate_profile')~=id then device:set_field('candidate_profile',id,{persist=true}) end
  local brand=device:get_field('candidate_brand')
  if not brand or not matches_brand(item,brand) then brand=item.brand end
  if device:get_field('candidate_brand')~=brand then device:set_field('candidate_brand',brand,{persist=true}) end
  local candidates={}
  for key,p in pairs(catalog) do if matches_brand(p,brand) then table.insert(candidates,p.name) end end
  table.sort(candidates)
  library_event(device,library.brand(brand,{state_change=true}),'brand',brand)
  library_event(device,library.supportedCandidates(candidates,{state_change=true,visibility={displayed=false}}),'supportedCandidates',candidates)
  library_event(device,library.candidate(item.name,{state_change=true}),'candidate',item.name)
end

local function finite_number(value)
  return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end
local function valid_list(values, check)
  if type(values)~='table' then return false end
  for key,value in pairs(values) do
    if type(key)~='number' or key%1~=0 or key<1 or key>#values or not check(value) then return false end
  end
  for i=1,#values do if not check(values[i]) then return false end end
  return true
end
local modes={cool=true,heat=true,auto=true,dry=true,fanOnly=true}
local function valid_settings(settings)
  if type(settings)~='table' then return false end
  return (settings.power==nil or type(settings.power)=='boolean')
    and (settings.mode==nil or modes[settings.mode]==true)
    and (settings.fan==nil or (type(settings.fan)=='string' and #settings.fan>0 and #settings.fan<=32))
    and (settings.target_temperature==nil or finite_number(settings.target_temperature))
end
local function valid_response(result)
  if type(result)~='table' or not valid_settings(result.state) then return false end
  if result.settings~=nil and not valid_settings(result.settings) then return false end
  if not valid_list(result.supported_modes,function(mode)return modes[mode]==true end)
    or not valid_list(result.supported_fans,function(fan)return type(fan)=='string' and #fan>0 and #fan<=32 end) then return false end
  if result.supported_keys~=nil and not valid_list(result.supported_keys,function(key)
    return type(key)=='table' and type(key.id)=='string' and #key.id>0
  end) then return false end
  if result.control_style~=nil and result.control_style~='state' and result.control_style~='buttons' then return false end
  if result.settings_save_pending~=nil and type(result.settings_save_pending)~='boolean' then return false end
  if result.temperature~=nil then
    local t=result.temperature
    if type(t)~='table' or not finite_number(t.min) or not finite_number(t.max) or not finite_number(t.step)
      or t.min>t.max or t.step<=0 then return false end
  end
  return true
end
local function warn(device,text)
  -- Logging and event publication can fail independently of LAN transmission.
  pcall(function() device.log.warn(text) end)
end
local function publish(device,fn)
  local ok=pcall(fn)
  if not ok then warn(device,'Tuya result publication failed; command will not be replayed') end
end

local function same_credentials(left,right)
  return left.bridgeIp==right.bridgeIp and tonumber(left.bridgePort)==tonumber(right.bridgePort)
    and left.bridgeToken==right.bridgeToken
end
local function same_context(left,right)
  return left and right and tostring(left.profile)==tostring(right.profile)
    and (not not left.testing)==(not not right.testing) and left.keys_open==right.keys_open
    and same_credentials(left.preferences,right.preferences)
end
local function current_request(device,request)
  local setup=not not in_setup(device)
  local profile=setup and (device:get_field('candidate_profile') or selected(device)) or selected(device)
  return tostring(request.profile)==tostring(profile) and (not not request.testing)==setup
    and request.keys_open==(not not device:get_field('keys_open'))
    and same_credentials(request.preferences,credentials(device))
end

local function same_value(left,right)
  if type(left)~=type(right) then return false end
  if type(left)~='table' then return left==right end
  for key,value in pairs(left) do if not same_value(value,right[key]) then return false end end
  for key in pairs(right) do if left[key]==nil then return false end end
  return true
end
local function copy_value(value)
  if type(value)~='table' then return value end
  local copied={}
  for key,item in pairs(value) do copied[key]=copy_value(item) end
  return copied
end
local function publication_context(device)
  local testing=not not in_setup(device)
  return {profile=testing and (device:get_field('candidate_profile') or selected(device)) or selected(device),
    testing=testing,keys_open=not not device:get_field('keys_open'),preferences=credentials(device)}
end
cached_emit=function(device,key,value,event,request)
  if request and not current_request(device,request) then return end
  local context=publication_context(device)
  local cache=device:get_field('published_events')
  if not cache or not same_context(cache.context,context) then
    cache={context=copy_value(context),values={},pending={}}
    device:set_field('published_events',cache)
  end
  if same_value(cache.values[key],value) then return end
  local token={}
  cache.pending[key]=token
  cache.values[key]=nil
  device:emit_event(event())
  -- An event may yield, fail, or reenter a view-change handler. Only remember a
  -- successful publication while this same cache and view are still current.
  if device:get_field('published_events')==cache and cache.pending[key]==token
    and same_context(context,publication_context(device)) then
    cache.pending[key]=nil
    cache.values[key]=copy_value(value)
  end
end

local function apply(device, result, testing, request)
  local function emit(key,value,event)
    cached_emit(device,key,value,event,request)
  end
  if not current_request(device,request) then return end
  local s = result.state
  device:set_field('has_remote_keys', #(result.supported_keys or {}) > 0)
  if device:supports_capability(remote_keys) then
    local keys={}
    for _,key in ipairs(result.supported_keys or {}) do table.insert(keys,key.id) end
    local chosen=device:get_field('remote_key')
    local found=false
    for _,id in ipairs(keys) do if id==chosen then found=true end end
    if not found then chosen=keys[1] or '' end
    device:set_field('remote_key',chosen)
    emit(remote_keys.ID..'.supportedKeys',keys,function() return remote_keys.supportedKeys(keys,{state_change=true,visibility={displayed=false}}) end)
    -- Publishing the list may yield to a newer user selection in this same
    -- view. Preserve it instead of displaying the earlier snapshot selection.
    if device:get_field('remote_key')==chosen then
      emit(remote_keys.ID..'.key',chosen,function() return remote_keys.key(chosen,{state_change=true}) end)
    end
  end
  if not current_request(device,request) then return end
  if result.control_style=='buttons' or device:get_field('keys_open') then
    connection_note(device,result.settings_save_pending and '명령 전송 완료 · 설정 저장 대기'
      or '버튼 전송 기준 · 실제 상태는 확인할 수 없습니다')
    return
  end
  if type(s.power) == 'boolean' then
    local power=s.power and 'on' or 'off'
    emit('switch.switch',power,function() return caps.switch.switch(power) end)
  end
  local settings=result.settings or s
  local tempcap=caps['earthpanel38939.'..(temperatures.by_id[tostring(request.profile)] or 'acTemp18To30')]
  if settings.target_temperature then
    local value={value=settings.target_temperature,unit='C'}
    if not testing and device:supports_capability(tempcap) then emit(tempcap.ID..'.temperature',value,function() return tempcap.temperature(value,{state_change=true,visibility={displayed=false}}) end) end
    emit('thermostatCoolingSetpoint.coolingSetpoint',value,function() return caps.thermostatCoolingSetpoint.coolingSetpoint(value) end)
  end
  if result.temperature then
    local t = result.temperature
    local range={minimum=t.min,maximum=t.max,step=t.step}
    if not testing and device:supports_capability(tempcap) then emit(tempcap.ID..'.temperatureRange',range,function() return tempcap.temperatureRange({value=range},{state_change=true,visibility={displayed=false}}) end) end
    emit('thermostatCoolingSetpoint.coolingSetpointRange',range,function() return caps.thermostatCoolingSetpoint.coolingSetpointRange({value=range,unit='C'}) end)
  end
  emit('airConditionerMode.supportedAcModes',result.supported_modes,function() return caps.airConditionerMode.supportedAcModes(result.supported_modes, {visibility={displayed=false}}) end)
  if device:supports_capability(mode_control) then
    emit(mode_control.ID..'.supportedModes',result.supported_modes,function() return mode_control.supportedModes(result.supported_modes, {state_change=true,visibility={displayed=false}}) end)
    if settings.mode then emit(mode_control.ID..'.mode',settings.mode,function() return mode_control.mode(settings.mode) end) end
  end
  emit('airConditionerFanMode.supportedAcFanModes',result.supported_fans,function() return caps.airConditionerFanMode.supportedAcFanModes(result.supported_fans, {visibility={displayed=false}}) end)
  if settings.mode then emit('airConditionerMode.airConditionerMode',settings.mode,function() return caps.airConditionerMode.airConditionerMode(settings.mode) end) end
  if settings.fan then emit('airConditionerFanMode.fanMode',settings.fan,function() return caps.airConditionerFanMode.fanMode(settings.fan) end) end
  if current_request(device,request) then
    connection_note(device,result.settings_save_pending and '명령 전송 완료 · 설정 저장 대기'
      or (s.power==nil and '전원 미확인 · 저장된 설정 기준' or '리모컨 명령 기준'))
  end
end

local function complete_request(device,request,ok,result,err)
  if ok and result and valid_response(result)
    and (result.profile_id==nil or tostring(result.profile_id)==tostring(request.profile)) then
    -- Connection status and UI publication cannot change a successful send
    -- into a transport failure. Neither path ever repeats the command.
    if same_credentials(request.preferences,credentials(device)) then
      publish(device,function() device:online() end)
    end
    publish(device,function()
      -- The socket may yield while a user changes the model or leaves setup.
      -- An old result must not repaint a different model or remote-key screen.
      if not current_request(device,request) then return end
      if not request.testing then apply(device,result,false,request) end
      if request.testing then
        apply(device,result,true,request)
        if request.changes and current_request(device,request) then note(device,'반응 확인 후 저장') end
      elseif request.changes and current_request(device,request) then
        note(device,'명령을 보냈습니다 · 실제 작동 상태는 확인할 수 없습니다')
      end
      if result.settings_save_pending and current_request(device,request) then connection_note(device,'명령 전송 완료 · 설정 저장 대기') end
    end)
    return true
  else
    if same_credentials(request.preferences,credentials(device)) and (not ok or err~='unsupported') then
      publish(device,function() device:offline() end)
    end
    publish(device,function()
      if not current_request(device,request) then return end
      note(device,'요청 실패 · 연결 또는 지원 조합을 확인하세요')
      if current_request(device,request) then
        connection_note(device,err=='unsupported' and '이 조합은 지원하지 않습니다' or '브리지 연결 확인 필요')
      end
    end)
    warn(device,'Tuya LAN request or response failed')
    return false
  end
end

local function transact(_, device, changes, profile, testing)
  if not Client.valid(credentials(device)) then
    connection_note(device,'연결 대기')
    return
  end
  local queue=device:get_field('requests') or {}
  if profile==nil and in_setup(device) then
    profile=device:get_field('candidate_profile') or selected(device)
    testing=true
  end
  local prefs={}
  for k,v in pairs(credentials(device)) do prefs[k]=v end
  local request={changes=changes,profile=profile or selected(device),testing=testing,
    keys_open=not not device:get_field('keys_open'),preferences=prefs}
  -- Keep the latest requested view, even while a prior socket operation yields.
  -- A successful command for that same view can satisfy its coalesced poll.
  if device:get_field('busy') and not changes then
    device:set_field('pending_refresh',request)
    return
  end
  table.insert(queue,request)
  device:set_field('requests',queue)
  if device:get_field('busy') then return end
  device:set_field('busy',true)
  local drained=pcall(function()
    local previous,successful
    while true do
      if #queue==0 then
        local pending=device:get_field('pending_refresh')
        device:set_field('pending_refresh',nil)
        if pending and (not successful or not same_context(pending,previous)) then
          table.insert(queue,pending)
        end
      end
      if #queue==0 then break end
      local request=table.remove(queue,1)
      successful=false
      local handled=pcall(function()
        local prefs=request.preferences
        prefs.remoteIndex=tonumber(request.profile)
        local ok,result,err=pcall(Client.request,prefs,request.changes)
        successful=complete_request(device,request,ok,result,err)
      end)
      previous=request
      if not handled then warn(device,'Tuya request processing failed; command will not be replayed') end
    end
  end)
  -- Always release the worker, even if processing or publication raises.
  device:set_field('busy',false)
  if not drained then warn(device,'Tuya request worker failed') end
end

local function refresh(driver, device)
  -- Profile changes are asynchronous; publish setup values again once attached.
  publish(device,function()
    if device:supports_capability(library) then
      show_candidate(device,device:get_field('candidate_profile') or selected(device))
      note(device,device:get_field('setup_note') or '제조사와 기종을 선택하세요',true)
    end
  end)
  transact(driver, device)
end
local function init(driver, device)
  update_view(device)
  show_candidate(device,device:get_field('candidate_profile') or selected(device))
  if not device:get_field('poll') then
    device:set_field('poll', device.thread:call_on_schedule(30, function() refresh(driver,device) end, 'tuya-poll'))
  end
  note(device,device:get_field('setup_note') or '기종을 선택하세요')
  refresh(driver, device)
end

local function info_changed(driver,device,event,args)
  local old=args and args.old_st_store and args.old_st_store.preferences or {}
  if old.changeModel~=device.preferences.changeModel then device:set_field('setup_closed',false,{persist=true}) end
  init(driver,device)
end

local function discovery(driver, _, should_continue)
  for _, dev in ipairs(driver:get_devices()) do
    if not Client.valid(credentials(dev)) then return end
  end
  if not should_continue() then return end
  driver:try_create_device({type='LAN', device_network_id='tuya-local-' .. tostring(os.time()) .. '-' .. tostring(math.random(100000,999999)),
    label='Tuya 에어컨 로컬', profile='tuya-local-ac.v1', manufacturer='Tuya', model='tuya.ir.ac',
    vendor_provided_label='Tuya IR AC Local'})
end

local function save_candidate(d,v)
        local id=v:get_field('candidate_profile')
        if not catalog[id] then return end
        v:set_field('active_profile',id,{persist=true})
        v:set_field('setup_closed',true,{persist=true})
        v:set_field('keys_open',false)
        v:set_field('setup_open',false,{persist=true})
        note(v,'저장했습니다')
        update_view(v)
        transact(d,v)
end

local definition={
  discovery=discovery,
  lifecycle_handlers={init=init, added=init, infoChanged=info_changed},
  capability_handlers={
    [remote_keys.ID]={
      selectKey=function(_,v,c)
        v:set_field('remote_key',c.args.key)
        cached_emit(v,remote_keys.ID..'.key',c.args.key,function() return remote_keys.key(c.args.key) end)
      end,
      sendKey=function(d,v)
        local key=v:get_field('remote_key')
        if key and key~='' then transact(d,v,{key=key}) end
      end,
      back=function(d,v)
        v:set_field('keys_open',false)
        update_view(v);refresh(d,v)
      end,
    },
    [mode_control.ID]={
      setMode=function(d,v,c) transact(d,v,{mode=c.args.mode}) end,
    },
    [connection.ID]={
      showKeys=function(d,v)
        if v:get_field('has_remote_keys')==false then
          connection_note(v,'이 코드셋에는 추가 버튼이 없습니다')
          return
        end
        v:set_field('keys_open',true)
        update_view(v);refresh(d,v)
      end,
      ['configure']=function(d,v)
        v:set_field('setup_open',true,{persist=true})
        update_view(v)
        show_candidate(v,selected(v))
        note(v,'각 기능을 시험하세요')
        refresh(d,v)
      end,
      ['done']=function(d,v)
        v:set_field('keys_open',false)
        v:set_field('setup_open',false,{persist=true})
        v:set_field('setup_closed',true,{persist=true})
        update_view(v);refresh(d,v)
      end,
      ['enroll']=function(d,v,c)
        connection_note(v,'연결 중')
        local ok,p=pcall(Client.enroll,c.args.address,c.args.port,c.args.ticket,v.id)
        if not ok or not p then connection_note(v,'연결을 다시 시도해 주세요'); return end
        v:set_field('bridge_credentials',p,{persist=true})
        update_view(v)
        refresh(d,v)
      end,
    },
    [library.ID]={
      [library.commands.setBrand.NAME]=function(d,v,c)
        local choices={}
        for id,p in pairs(catalog) do if matches_brand(p,c.args.brand) then table.insert(choices,id) end end
        table.sort(choices)
        if choices[1] then v:set_field('candidate_brand',c.args.brand,{persist=true}); show_candidate(v,choices[1]); update_view(v); note(v,'각 기능을 시험하세요'); refresh(d,v) end
      end,
      [library.commands.setCandidate.NAME]=function(d,v,c) show_candidate(v,c.args.candidate); update_view(v); note(v,'각 기능을 시험하세요'); refresh(d,v) end,
      [library.commands.applyCode.NAME]=save_candidate,
    },
    [caps.refresh.ID]={[caps.refresh.commands.refresh.NAME]=refresh},
    [caps.switch.ID]={
      [caps.switch.commands.on.NAME]=function(d,v) transact(d,v,{power=true}) end,
      [caps.switch.commands.off.NAME]=function(d,v) transact(d,v,{power=false}) end,
    },
    [caps.airConditionerMode.ID]={
      [caps.airConditionerMode.commands.setAirConditionerMode.NAME]=function(d,v,c) transact(d,v,{mode=c.args.mode}) end,
    },
    [caps.airConditionerFanMode.ID]={
      [caps.airConditionerFanMode.commands.setFanMode.NAME]=function(d,v,c) transact(d,v,{fan=c.args.fanMode}) end,
    },
    [caps.thermostatCoolingSetpoint.ID]={
      [caps.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME]=function(d,v,c)
        local value=c.args.setpoint
        if c.args.unit == 'F' then value=(value-32)*5/9 end
        transact(d,v,{target_temperature=value})
      end,
    },
  },
}
for _,name in ipairs(temperatures.types) do
  definition.capability_handlers['earthpanel38939.'..name]={setTemperature=function(d,v,c)
    transact(d,v,{target_temperature=c.args.temperature})
  end}
end
Driver('tuya-ac-local',definition):run()
