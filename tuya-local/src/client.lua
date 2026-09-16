local socket = require 'cosock.socket'
local json = require 'st.json'
local Client = {}

local function address_valid(p)
  if type(p)~='table' or type(p.bridgeIp)~='string' then return false end
  local a,b,c,d=p.bridgeIp:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if not a then return false end
  for _,n in ipairs({a,b,c,d}) do if tonumber(n)>255 then return false end end
  local port=tonumber(p.bridgePort)
  return port and port>=1 and port<=65535 and port%1==0
end
function Client.valid(p)
  return address_valid(p) and type(p.bridgeToken)=='string' and #p.bridgeToken>=32
    and p.bridgeToken:match('^[A-Za-z0-9]+$')~=nil
end

local function exchange(p,path,changes,token)
  if not address_valid(p) then return nil,'invalid address' end
  local s=socket.tcp(); s:settimeout(15)
  local ok,result,code=pcall(function()
    assert(s:connect(p.bridgeIp,tonumber(p.bridgePort)))
    local body=changes and json.encode(changes) or ''
    local method=changes and 'POST' or 'GET'
    local request=method..' '..path..' HTTP/1.1\r\nHost: '..p.bridgeIp..'\r\nConnection: close\r\n'
    if token then request=request..'Authorization: Bearer '..token..'\r\n' end
    if p.remoteIndex then
      local profile=tonumber(p.remoteIndex)
      assert(profile and profile>0 and profile%1==0,'invalid code set')
      request=request..'X-IR-Profile: '..tostring(profile)..'\r\n'
    end
    request=request..'Content-Type: application/json\r\nContent-Length: '..#body..'\r\n\r\n'..body
    local offset=1
    while offset<=#request do
      local sent,err,last=s:send(request,offset)
      if sent then offset=sent+1 elseif last and last>=offset then offset=last+1 else error(err or 'send failed') end
    end
    local status=assert(s:receive('*l'))
    local status_code=tonumber(status:match('^HTTP/%d%.%d (%d%d%d)'))
    local length
    for i=1,32 do
      local line=assert(s:receive('*l'))
      if line=='' then break end
      local value=line:lower():match('^content%-length:%s*(%d+)$')
      if value then length=tonumber(value) end
      if i==32 then error('too many headers') end
    end
    assert(length and length>0 and length<=16384,'bad body size')
    return json.decode(assert(s:receive(length))),status_code
  end)
  s:close()
  if not ok then return nil,'unreachable' end
  if code~=200 then return nil,code==400 and 'unsupported' or code==401 and 'authentication' or 'unreachable' end
  return result
end
function Client.enroll(address,port,ticket,device_id)
  local p={bridgeIp=address,bridgePort=port}
  if type(ticket)~='string' or not ticket:match('^[a-f0-9]+$') or #ticket~=64 then return nil end
  local result=exchange(p,'/v1/pair',{ticket=ticket,device_id=device_id})
  if type(result)~='table' then return nil end
  p.bridgeToken=result.api_token
  if Client.valid(p) then return p end
end
function Client.request(p,changes)
  if not Client.valid(p) then return nil,'authentication' end
  local result,err=exchange(p,changes and '/v1/command' or '/v1/state',changes,p.bridgeToken)
  if not result then return nil,err end
  if type(result)~='table' or result.reachable~=true or result.state_source~='last_ir_command' then return nil,'unreachable' end
  return result
end
return Client
