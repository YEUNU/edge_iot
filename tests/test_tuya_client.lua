-- Exercise the real HTTP client against a scripted socket, without LAN traffic.
package.path='tuya-local/src/?.lua;'..package.path
local current,opened
package.preload['cosock.socket']=function()return {tcp=function()
 opened=opened+1
 local s={lines=current.lines or {'HTTP/1.1 200 OK','Content-Length: 2',''},index=0,wire='',closed=false}
 current.socket=s
 function s:settimeout()end
 function s:connect()if current.connect_error then return nil,'timeout' end return true end
 function s:send(data,offset)
  if current.send_error then return nil,'closed',0 end
  local finish=current.partial and math.min(offset+6,#data) or #data
  self.wire=self.wire..data:sub(offset,finish)
  if current.partial and finish<#data then return nil,'timeout',finish end
  return finish
 end
 function s:receive(size)
  if size=='*l' then self.index=self.index+1;return self.lines[self.index] end
  if current.truncated then return nil,'closed','{' end
  return '{}'
 end
 function s:close()self.closed=true end
 return s
end}end
package.preload['st.json']=function()return {
 encode=function()return '{}'end,
 decode=function()if current.bad_json then error('bad JSON')end return current.body or {reachable=true,state_source='last_ir_command',state={}}end
}end
local client=require 'client'
local prefs={bridgeIp='192.168.1.49',bridgePort=8766,bridgeToken=string.rep('a',64),remoteIndex=104800501}
local passed=0
local function test(name,fn)current={};opened=0;fn();passed=passed+1;print('PASS '..name)end
local function failure(expected)
 local result,err=client.request(prefs)
 assert(not result and err==expected,tostring(err));assert(current.socket.closed)
end
test('partial writes preserve complete authenticated request',function()
 current.partial=true;assert(client.request(prefs,{power=false}))
 assert(current.socket.wire:find('POST /v1/command HTTP/1.1',1,true))
 assert(current.socket.wire:find('Authorization: Bearer '..prefs.bridgeToken,1,true))
 assert(current.socket.wire:find('X-IR-Profile: 104800501',1,true));assert(current.socket.closed)
end)
for _,case in ipairs({{400,'unsupported'},{401,'authentication'},{403,'unreachable'},{502,'unreachable'}})do
 test('HTTP '..case[1],function()current.lines={'HTTP/1.1 '..case[1]..' Error','Content-Length: 2',''};failure(case[2])end)
end
for _,name in ipairs({'connect_error','send_error','truncated','bad_json'})do
 test(name,function()current[name]=true;failure('unreachable')end)
end
for _,lines in ipairs({{'INVALID','Content-Length: 2',''},{'HTTP/1.1 200 OK',''},{'HTTP/1.1 200 OK','Content-Length: 16385',''},{'HTTP/1.1 200 OK','Content-Length: 0',''}})do
 test('malformed or oversized response',function()current.lines=lines;failure('unreachable')end)
end
test('untrusted response cannot report online',function()current.body={reachable=true,state_source='measured'};failure('unreachable')end)
test('unexpected JSON scalar is rejected',function()current.body=123;failure('unreachable')end)
test('invalid credentials never connect',function()
 for _,p in ipairs({{}, {bridgeIp='999.1.1.1',bridgePort=8766,bridgeToken=prefs.bridgeToken},{bridgeIp=prefs.bridgeIp,bridgePort=1.5,bridgeToken=prefs.bridgeToken},{bridgeIp=prefs.bridgeIp,bridgePort=8766,bridgeToken='bad\r\n'}})do assert(not client.request(p))end
 assert(opened==0)
end)
test('enrollment exchanges ticket without bearer and validates result',function()
 current.body={api_token=prefs.bridgeToken}
 local result=client.enroll(prefs.bridgeIp,8766,string.rep('b',64),'owned-device')
 assert(result.bridgeToken==prefs.bridgeToken)
 assert(current.socket.wire:find('POST /v1/pair',1,true));assert(not current.socket.wire:find('Authorization',1,true))
 current.body={api_token='short'};assert(not client.enroll(prefs.bridgeIp,8766,string.rep('b',64),'owned-device'))
end)
test('failed request recovers on next request',function()
 current.connect_error=true;failure('unreachable');current.connect_error=false;assert(client.request(prefs))
end)
print(passed..' transport cases passed')
