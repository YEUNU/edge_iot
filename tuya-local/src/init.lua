local Driver = require 'st.driver'
local caps = require 'st.capabilities'
local Client = require 'client'
local catalog = require 'catalog'
local temperatures = require 'temperature_profiles'
local library = caps['earthpanel38939.acModelLibrary']
local connection = caps['earthpanel38939.acLocalLink']
local remote_keys = caps['earthpanel38939.acRemoteKeys']
local mode_control = caps['earthpanel38939.acModeControl']
local function connection_note(device,text)
  if device:supports_capability(connection) then device:emit_event(connection.status(text)) end
end
local function library_event(device,event)
  if device:supports_capability(library) then device:emit_event(event) end
end
local function note(device,text)
  device:set_field('setup_note',text)
  library_event(device,library.status(text,{state_change=true}))
end
local function credentials(device)
  return device:get_field('bridge_credentials') or device.preferences
end
local function in_setup(device)
  return device:get_field('setup_open') or (device.preferences.changeModel and not device:get_field('setup_closed'))
end
local function update_view(device)
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
  device:set_field('candidate_profile',id,{persist=true})
  local brand=device:get_field('candidate_brand')
  if not brand or not matches_brand(item,brand) then brand=item.brand end
  device:set_field('candidate_brand',brand,{persist=true})
  local candidates={}
  for key,p in pairs(catalog) do if matches_brand(p,brand) then table.insert(candidates,p.name) end end
  table.sort(candidates)
  library_event(device,library.brand(brand,{state_change=true}))
  library_event(device,library.supportedCandidates(candidates,{state_change=true,visibility={displayed=false}}))
  library_event(device,library.candidate(item.name,{state_change=true}))
end

local function apply(device, result, testing)
  local s = result.state
  if type(s) ~= 'table' then device:offline(); return end
  device:set_field('has_remote_keys', #(result.supported_keys or {}) > 0)
  if device:supports_capability(remote_keys) then
    local keys={}
    for _,key in ipairs(result.supported_keys or {}) do table.insert(keys,key.id) end
    local chosen=device:get_field('remote_key')
    local found=false
    for _,id in ipairs(keys) do if id==chosen then found=true end end
    if not found then chosen=keys[1] or '' end
    device:set_field('remote_key',chosen)
    device:emit_event(remote_keys.supportedKeys(keys,{state_change=true,visibility={displayed=false}}))
    device:emit_event(remote_keys.key(chosen,{state_change=true}))
  end
  if result.control_style=='buttons' or device:get_field('keys_open') then
    connection_note(device,'버튼 전송 기준 · 실제 상태는 확인할 수 없습니다')
    device:online()
    return
  end
  if type(s.power) == 'boolean' then
    device:emit_event(caps.switch.switch(s.power and 'on' or 'off'))
  end
  local settings=result.settings or s
  local tempcap=caps['earthpanel38939.'..(temperatures.by_id[selected(device)] or 'acTemp18To30')]
  if settings.target_temperature then
    if not testing and device:supports_capability(tempcap) then device:emit_event(tempcap.temperature({value=settings.target_temperature,unit='C'},{state_change=true,visibility={displayed=false}})) end
    device:emit_event(caps.thermostatCoolingSetpoint.coolingSetpoint({value=settings.target_temperature,unit='C'}))
  end
  if result.temperature then
    local t = result.temperature
    if not testing and device:supports_capability(tempcap) then device:emit_event(tempcap.temperatureRange({value={minimum=t.min,maximum=t.max,step=t.step}},{state_change=true,visibility={displayed=false}})) end
    device:emit_event(caps.thermostatCoolingSetpoint.coolingSetpointRange({value={minimum=t.min,maximum=t.max,step=t.step},unit='C'}))
  end
  device:emit_event(caps.airConditionerMode.supportedAcModes(result.supported_modes, {visibility={displayed=false}}))
  if device:supports_capability(mode_control) then
    device:emit_event(mode_control.supportedModes(result.supported_modes, {state_change=true,visibility={displayed=false}}))
    if settings.mode then device:emit_event(mode_control.mode(settings.mode)) end
  end
  device:emit_event(caps.airConditionerFanMode.supportedAcFanModes(result.supported_fans, {visibility={displayed=false}}))
  if settings.mode then device:emit_event(caps.airConditionerMode.airConditionerMode(settings.mode)) end
  if settings.fan then device:emit_event(caps.airConditionerFanMode.fanMode(settings.fan)) end
  connection_note(device,'리모컨 명령 기준')
  device:online()
end

local function transact(_, device, changes, profile, testing)
  if not Client.valid(credentials(device)) then
    connection_note(device,'연결 대기')
    return
  end
  local queue=device:get_field('requests') or {}
  -- Polls may coalesce; user commands must not be silently dropped.
  if device:get_field('busy') and not changes then return end
  if profile==nil and in_setup(device) then
    profile=device:get_field('candidate_profile') or selected(device)
    testing=true
  end
  table.insert(queue,{changes=changes,profile=profile or selected(device),testing=testing})
  device:set_field('requests',queue)
  if device:get_field('busy') then return end
  device:set_field('busy',true)
  while #queue>0 do
    local request=table.remove(queue,1)
    local prefs={}
    for k,v in pairs(credentials(device)) do prefs[k]=v end
    prefs.remoteIndex=tonumber(request.profile)
    local ok,result,err=pcall(Client.request,prefs,request.changes)
    if ok and result then
      if not request.testing then apply(device,result) end
      if request.testing and in_setup(device) and tostring(request.profile)==tostring(device:get_field('candidate_profile')) then
        apply(device,result,true)
        if request.changes then note(device,'반응 확인 후 저장') end
      else
        if request.changes then note(device,'명령을 보냈습니다 · 실제 작동 상태는 확인할 수 없습니다') end
      end
    else
      note(device,'요청 실패 · 연결 또는 지원 조합을 확인하세요')
      connection_note(device,err=='unsupported' and '이 조합은 지원하지 않습니다' or '브리지 연결 확인 필요')
      if not ok or err~='unsupported' then device:offline() end
      device.log.warn('Tuya LAN request failed')
    end
  end
  device:set_field('busy',false)
end

local function refresh(driver, device)
  -- Profile changes are asynchronous; publish setup values again once attached.
  if device:supports_capability(library) then
    show_candidate(device,device:get_field('candidate_profile') or selected(device))
    note(device,device:get_field('setup_note') or '제조사와 기종을 선택하세요')
  end
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
        v:emit_event(remote_keys.key(c.args.key))
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
