-- Exercise actual lifecycle entry points without connecting to appliances.
package.path = 'xiaomi-miio/src/?.lua;' .. package.path
local config
local refreshes = 0
local noop = function() end
package.preload.log = function() return {info=noop,warn=noop,error=noop} end
package.preload['st.driver'] = function() return function(_, value)
  config=value; return {run=noop}
end end
package.preload['st.capabilities'] = function()
  return setmetatable({}, {__index=function(_, id)
    return setmetatable({ID=id,commands=setmetatable({}, {__index=function(_, k) return {NAME=k} end})},
      {__index=function(_, attr) return function(value) return {capability=id,attribute=attr,value=value} end end})
  end})
end
package.preload.discovery = function() return {restore=noop,scan=noop,handle=noop} end
package.preload.command_handlers = function() return {refresh=function() refreshes=refreshes+1 end} end
package.preload.alerts = function() return {is_endpoint=function() return false end,attach=noop} end
for _, name in ipairs({'fan_za5','airp_cpa4','derh_13l'}) do
  package.preload['devices.'..name] = function() return {} end
end
require 'init'
local function device(model, prefs)
  local fields={}
  return {model=model,preferences=prefs or {},device_network_id='test',id='test',log=require 'log',
    get_field=function(_,k) return fields[k] end,set_field=function(_,k,v) fields[k]=v end,
    online=function(self) self.health='ONLINE' end,offline=function(self) self.health='OFFLINE' end,
    try_update_metadata=function(self,m) self.metadata=m end,emit_event=noop,
    thread={call_on_schedule=noop}}
end
for _, prefs in ipairs({{}, {deviceModel='fan_za5',deviceIp='0.0.0.0',deviceToken=string.rep('0',32)}}) do
  local d=device('xiaomi.setup',prefs)
  config.lifecycle_handlers.added({},d)
  assert(d.health=='ONLINE','setup must be usable before enrollment')
  config.lifecycle_handlers.init({},d)
  assert(d.health=='ONLINE' and not d:get_field('client'))
  config.lifecycle_handlers.infoChanged({},d,nil,{old_st_store={preferences={}}})
  assert(d.health=='ONLINE','editing incomplete setup must not mark it offline')
end
local physical=device('zhimi.fan.za5')
config.lifecycle_handlers.init({},physical)
assert(physical.health=='OFFLINE','a real unconfigured appliance must remain offline')
local ready=device('xiaomi.setup',{deviceModel='fan_za5',deviceIp='192.168.1.2',deviceToken=string.rep('12',16)})
config.lifecycle_handlers.init({},ready)
assert(ready:get_field('client') and refreshes==1,'completed setup must attach and verify real device')
print('PASS: setup health, default model, incomplete edits, real appliance and enrollment transition')
