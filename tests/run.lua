local root = (... and ... ~= "" and ...) or "."
package.path = table.concat({
  root .. "/xiaomi-miio/src/?.lua",
  root .. "/xiaomi-miio/src/?/?.lua",
  package.path,
}, ";")

local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    io.stderr:write("FAIL: " .. name .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  passed = passed + 1
  print("PASS: " .. name)
end

local md5 = require "miio.md5"
local packet = require "miio.packet"
local Client = require "miio.client"

test("MD5 RFC vector", function()
  assert(md5.hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
end)

test("miIO packet round-trip", function()
  local token = string.rep("\x01", 16)
  local body = '{"id":1,"method":"miIO.info","params":[]}'
  local raw = packet.build(token, 0x01020304, 123456, body)
  local device_id, stamp, decoded, err = packet.parse(token, raw)
  assert(not err, err)
  assert(device_id == 0x01020304)
  assert(stamp == 123456)
  assert(decoded == body)
end)

test("miIO packet rejects tampering", function()
  local token = string.rep("\x02", 16)
  local raw = packet.build(token, 1, 2, '{"id":1}')
  local last = raw:byte(-1)
  local corrupt = raw:sub(1, -2) .. string.char(last ~ 0x01)
  local _, _, _, err = packet.parse(token, corrupt)
  assert(err == "checksum mismatch", tostring(err))
end)

test("miIO client validates token", function()
  local client, err = Client.new{ ip = "192.168.1.2", token = string.rep("z", 32) }
  assert(client == nil)
  assert(err:match("hexadecimal"))
  assert(Client.new{ ip = "192.168.1.2", token = string.rep("a", 32) })
end)

test("miIO set_property accepts code zero", function()
  local client = assert(Client.new{ ip = "192.168.1.2", token = string.rep("a", 32) })
  client.set_properties = function()
    return { { did = "power", code = 0 } }
  end
  assert(client:set_property(2, 1, true, "power") == true)
end)

test("miIO set_property rejects device error", function()
  local client = assert(Client.new{ ip = "192.168.1.2", token = string.rep("a", 32) })
  client.set_properties = function()
    return { { did = "power", code = -9999 } }
  end
  local ok, err = client:set_property(2, 1, true, "power")
  assert(ok == nil)
  assert(err:match("%-9999"), err)
end)

test("miIO action accepts code zero", function()
  local client = assert(Client.new{ ip = "192.168.1.2", token = string.rep("a", 32) })
  client.send_raw = function() return "response" end
  client._parse_reply = function() return { { did = "reset-filter", code = 0 } } end
  assert(client:action(4, 1, { 0 }, "reset-filter") == true)
end)

test("miIO action rejects device error", function()
  local client = assert(Client.new{ ip = "192.168.1.2", token = string.rep("a", 32) })
  client.send_raw = function() return "response" end
  client._parse_reply = function() return { { did = "reset-filter", code = -1 } } end
  local ok, err = client:action(4, 1, { 0 }, "reset-filter")
  assert(ok == nil)
  assert(err:match("%-1"), err)
end)

-- Scripted UDP sockets exercise the real codec/client without LAN traffic.
local function transport_fixture(options, replies)
  local now, sockets = 100, {}
  local transport = {
    gettime = function() return now end,
    udp = function()
      local s = {sent = {}, closed = false}
      sockets[#sockets + 1] = s
      function s:settimeout(value) self.timeout = value; return 1 end
      function s:setsockname() return 1 end
      function s:sendto(body)
        self.sent[#self.sent + 1] = body
        if options.send_error then return nil, "send failed" end
        return #body
      end
      function s:receivefrom()
        local reply = table.remove(replies, 1) or {}
        local wait = reply.delay or 0
        if wait >= self.timeout then now = now + self.timeout; return nil, "timeout" end
        now = now + wait
        return reply.raw, reply.ip or "192.168.1.2", reply.port or 54321
      end
      function s:close() self.closed = true end
      return s
    end,
  }
  local previous = package.loaded["cosock.socket"]
  package.loaded["cosock.socket"] = transport
  local MockClient = dofile(root .. "/xiaomi-miio/src/miio/client.lua")
  package.loaded["cosock.socket"] = previous
  local client = assert(MockClient.new{
    ip = "192.168.1.2", token = string.rep("ab", 16), timeout_s = options.timeout or 2,
    deadline = options.deadline,
    expected_did = options.expected_did,
  })
  return client, sockets, function() return now end
end

local function client_hello(did)
  return string.pack(">I2I2I4I4I4", 0x2131, 32, 0, did, 100) .. string.rep("\255", 16)
end
local function client_reply(did, body)
  return packet.build(string.rep("\xab", 16), did, 100, body)
end

test("miIO rejects invalid timeout and deadline options", function()
  for _, timeout in ipairs({0, -1, math.huge, 0/0, "2", false}) do
    assert(not Client.new{ip="192.168.1.2", token=string.rep("ab",16), timeout_s=timeout})
  end
  for _, deadline in ipairs({math.huge, 0/0, "soon", false}) do
    assert(not Client.new{ip="192.168.1.2", token=string.rep("ab",16), deadline=deadline})
  end
  assert(not Client.new("invalid"))
end)

test("miIO deadline bounds all phases and retries", function()
  local client, sockets, now = transport_fixture({deadline=103}, {
    {raw=client_hello(123),delay=1.9}, {delay=2},
  })
  local result, err = client:send_raw('{"id":1}')
  assert(not result and err=="deadline exceeded", tostring(err))
  assert(now()==103 and #sockets==1 and sockets[1].closed)
  client, sockets = transport_fixture({deadline=100}, {})
  local did, _, handshake_err = client:handshake()
  assert(not did and handshake_err=="deadline exceeded" and #sockets==0)
end)

test("miIO rejects unexpected UDP sources and malformed hello identities", function()
  for _, reply in ipairs({
    {raw=client_hello(123),ip="192.168.1.3"},
    {raw=client_hello(123),port=12345},
    {raw=client_hello(0)}, {raw=client_hello(0xFFFFFFFF)},
    {raw=client_reply(123,'{"id":1,"result":{}}')}, {raw="short"},
  }) do
    local client, sockets = transport_fixture({}, {reply})
    local did = client:handshake()
    assert(not did and #sockets==1 and sockets[1].closed)
  end
end)

test("miIO binds encrypted replies and retry handshakes to the same device", function()
  local client, sockets = transport_fixture({}, {
    {raw=client_reply(456,'{"id":1,"result":{}}')},
    {raw=client_hello(456)}, {raw=client_hello(456)},
  })
  local result = client:send_raw('{"id":1}', {dev_id=123,base_stamp=100,base_time=os.time()})
  assert(not result and #sockets==3)
  local rpc_count = 0
  for _, s in ipairs(sockets) do
    assert(s.closed)
    for _, body in ipairs(s.sent) do if #body>32 then rpc_count=rpc_count+1 end end
  end
  assert(rpc_count==1, "identity-changing retries must never send another RPC")
end)

test("miIO session info validates both response identities", function()
  local client = transport_fixture({}, {{raw=client_reply(123,'{"id":1,"result":{"model":"zhimi.fan.za5"}}')}})
  local info = assert(client:miio_info({dev_id=123,base_stamp=100,base_time=os.time()}))
  assert(info.model=="zhimi.fan.za5")
  client = transport_fixture({}, {{raw=client_reply(123,'{"id":2,"result":{"model":"zhimi.fan.za5"}}')}})
  local result, err = client:miio_info({dev_id=123,base_stamp=100,base_time=os.time()})
  assert(not result and err=="reply request identity mismatch")
end)

test("miIO malformed JSON-RPC and property results return errors", function()
  for _, body in ipairs({'null', 'true', '42', '"response"', '{',
    '{"id":1,"error":"failed"}', '{"id":1,"result":true}',
    '{"id":1,"result":null}', '{"id":1,"result":[]}',
    '{"id":1,"result":[true]}', '{"id":1,"result":[{"code":null}]}',
    '{"id":1,"result":[{"code":0},null,{"code":-1}]}',
    '{"id":1,"result":[{"code":0.5}]}',
    '{"id":1,"result":{"power":{"code":0}}}',
    '{"id":1,"result":[{"code":0}]} trailing data',
  }) do
    local client = assert(Client.new{ip="192.168.1.2",token=string.rep("ab",16)})
    client.send_raw = function() return body end
    local result, err = client:get_properties({{siid=2,piid=1,did="power"}})
    assert(not result and err, body)
  end
end)

test("miIO hello send failure closes socket without receiving", function()
  local client, sockets, now = transport_fixture({send_error=true}, {{delay=1}})
  local did = client:handshake()
  assert(not did and sockets[1].closed and now()==100)
end)

package.preload["log"] = function()
  return { info = function() end, warn = function() end, error = function() end }
end
local cosock_sleeps = {}
package.preload["cosock"] = function()
  return {
    socket = { sleep = function(seconds) cosock_sleeps[#cosock_sleeps + 1] = seconds end },
    spawn = function(fn) fn() end,
  }
end
package.preload["st.capabilities"] = function()
  return setmetatable({}, {
    __index = function(_, capability_id)
      return setmetatable({ ID = capability_id }, {
        __index = function(_, attribute_id)
          if attribute_id == "commands" then
            return setmetatable({}, {
              __index = function(_, name) return { NAME = name } end,
            })
          end
          return setmetatable({}, {
            __call = function(_, ...)
              return {
                capability = capability_id,
                attribute = attribute_id,
                args = { ... },
              }
            end,
            __index = function(_, method)
              return function(...)
                return {
                  capability = capability_id,
                  attribute = attribute_id,
                  method = method,
                  args = { ... },
                }
              end
            end,
          })
        end,
      })
    end,
  })
end

local command_handlers = require "command_handlers"
local discovery = require "discovery"
require("miio.discover").scan = function() return {} end
local fan = require "devices.fan_za5"
local airp = require "devices.airp_cpa4"
local dehumidifier = require "devices.derh_13l"

test("discovery creates one generic Xiaomi setup device", function()
  local created
  local driver = {
    get_devices = function() return {} end,
    try_create_device = function(_, metadata)
      created = metadata
      return true
    end,
  }
  discovery.handle(driver, nil, function() return true end)
  assert(created)
  assert(created.profile == "xiaomi-setup.v1")
  assert(created.model == "xiaomi.setup")
end)

test("discovery does not duplicate an unfinished setup device", function()
  local created = false
  local driver = {
    get_devices = function() return { { model = "xiaomi.setup" } } end,
    try_create_device = function() created = true end,
  }
  discovery.handle(driver, nil, function() return true end)
  assert(created == false)
end)

local function recording_client()
  local calls = {}
  return {
    get_properties = function(_, props)
      local result = {}
      for _, prop in ipairs(props) do
        local value = 0
        if prop.did == "power" or prop.did == "timer-enabled" then value = false end
        result[#result + 1] = { did = prop.did, code = 0, value = value }
      end
      return result
    end,
    set_property = function(_, siid, piid, value, did)
      calls[#calls + 1] = { siid = siid, piid = piid, value = value, did = did }
      return true
    end,
    action = function(_, siid, aiid, args, did)
      calls[#calls + 1] = { siid = siid, aiid = aiid, args = args, did = did }
      return true
    end,
  }, calls
end

test("fan setters use expected MiOT properties", function()
  local client, calls = recording_client()
  assert(fan.set_fan_speed_percent(client, 74))
  assert(calls[1].siid == 2 and calls[1].piid == 1 and calls[1].value == true)
  assert(calls[2].siid == 6 and calls[2].piid == 8 and calls[2].value == 74)
  assert(fan.set_mode(client, "자연풍"))
  assert(calls[3].siid == 2 and calls[3].piid == 7 and calls[3].value == 0)
  assert(fan.set_oscillation_angle(client, 90))
  assert(calls[4].siid == 2 and calls[4].piid == 5 and calls[4].value == 90)
  assert(fan.set_power_off_timer(client, 60))
  assert(calls[5].siid == 2 and calls[5].piid == 10 and calls[5].value == 3600)
  assert(fan.set_indicator(client, "dim"))
  assert(calls[6].siid == 4 and calls[6].piid == 3 and calls[6].value == 50)
end)

test("profile-aware events hide unsupported capabilities", function()
  local profile_events = require "devices.events"
  local emitted = 0
  local device = {
    supports_capability = function() return false end,
    emit_event = function() emitted = emitted + 1 end,
  }
  profile_events.emit(device, { ID = "advanced" }, {})
  assert(emitted == 0)
  device.supports_capability = function() return true end
  profile_events.emit(device, { ID = "simple" }, {})
  assert(emitted == 1)
end)

test("device polling separates core and auxiliary properties", function()
  assert(#fan.core_props == 5 and #fan.aux_props == 6)
  assert(#airp.core_props == 6 and #airp.aux_props == 5)
  assert(#dehumidifier.core_props == 9 and #dehumidifier.aux_props == 6)
end)

test("air purifier basic profile advertises filter reset", function()
  local emitted = {}
  airp.on_init({
    emit_event = function(_, event) emitted[#emitted + 1] = event end,
  })
  local found = false
  for _, event in ipairs(emitted) do
    if event.capability == "filterState" and event.attribute == "supportedFilterCommands" then
      found = event.args[1][1] == "resetFilter"
    end
  end
  assert(found)
end)

local function optimistic_fixture(kind, expected, reads)
  local events = {}
  local state = { online = false, offline = false, applied = {} }
  local props = {}
  for did in pairs(expected) do
    props[#props + 1] = { siid = 1, piid = #props + 1, did = did }
  end
  local handler = {
    is_fan = kind == "fan",
    refresh_props = props,
    core_props = props,
    apply_state = function(_, values)
      state.applied[#state.applied + 1] = values
    end,
  }
  if kind == "fan" then
    handler.set_fan_speed_percent = function(_, value)
      return true, nil, { power = value > 0, ["speed-percent"] = value > 0 and value or nil }
    end
  elseif kind == "airp" then
    handler.set_favorite_level = function(_, value)
      return true, nil, { power = true, mode = 2, ["favorite-level"] = value }
    end
  end
  local read_index = 0
  local client = {
    begin_session = function() return {} end,
    get_properties = function(_, chunk)
      read_index = read_index + 1
      local values = reads[math.min(read_index, #reads)]
      local result = {}
      for _, prop in ipairs(chunk) do
        result[#result + 1] = { did = prop.did, code = 0, value = values[prop.did] }
      end
      return result
    end,
  }
  local device = {
    label = kind,
    get_field = function(_, key)
      if key == "handler_module" then return handler end
      if key == "client" then return client end
    end,
    emit_event = function(_, event) events[#events + 1] = event end,
    online = function() state.online = true end,
    offline = function() state.offline = true end,
  }
  return device, events, state
end

test("dehumidifier mode confirmation refreshes device target humidity", function()
  for _, mode in ipairs(dehumidifier.supported_modes) do
    local emitted, requests = {}, {}
    local mode_code
    local client = {
      set_property = function(_, _, _, value) mode_code = value; return true end,
      begin_session = function() return {} end,
      get_properties = function(_, props)
        local result = {}
        for _, prop in ipairs(props) do
          requests[prop.did] = true
          result[#result + 1] = { did = prop.did, code = 0,
            value = prop.did == "mode" and mode_code or 55 }
        end
        return result
      end,
    }
    local device = {
      label = "dehumidifier",
      get_field = function(_, key)
        return key == "handler_module" and dehumidifier or client
      end,
      emit_event = function(_, event) emitted[#emitted + 1] = event end,
      online = function() end,
      offline = function() error("unexpected offline") end,
    }
    command_handlers.set_mode(nil, device, { args = { mode = mode } })
    assert(requests.mode and requests.target)
    local target
    for _, event in ipairs(emitted) do
      if event.attribute == "targetHumidity" then target = event.args[1].value end
    end
    assert(target == 55, "must reflect the actual device target")
  end
end)

test("missing related humidity is retried after mode confirmation", function()
  cosock_sleeps = {}
  local device, _, state = optimistic_fixture("derh", { mode = 1, target = 55 },
    { { mode = 1 }, { mode = 1, target = 55 } })
  local handler = device:get_field("handler_module")
  handler.confirmation_dependencies = dehumidifier.confirmation_dependencies
  handler.set_mode = function() return true, nil, { mode = 1 } end
  command_handlers.set_mode(nil, device, { args = { mode = "수면" } })
  assert(#cosock_sleeps == 2 and cosock_sleeps[2] == 1.5)
  assert(state.applied[1].target == 55)
end)

test("fan speed optimistic UI also updates power", function()
  cosock_sleeps = {}
  local expected = { power = true, ["speed-percent"] = 55 }
  local device, emitted = optimistic_fixture("fan", expected, { expected })
  command_handlers.set_fan_speed_percent(nil, device, { args = { percent = 55 } })
  assert(#emitted == 2)
  assert(emitted[1].capability == "fanSpeedPercent")
  assert(emitted[2].capability == "switch" and emitted[2].method == "on")
  assert(#cosock_sleeps == 1 and cosock_sleeps[1] == 0.5,
    "sleeps=" .. table.concat(cosock_sleeps, ","))
end)

test("fan speed zero optimistic UI turns power off", function()
  cosock_sleeps = {}
  local expected = { power = false }
  local device, emitted = optimistic_fixture("fan", expected, { expected })
  command_handlers.set_fan_speed_percent(nil, device, { args = { percent = 0 } })
  assert(#emitted == 2)
  assert(emitted[1].args[1] == 0)
  assert(emitted[2].capability == "switch" and emitted[2].method == "off")
end)

test("air purifier favorite optimistic UI updates level power and mode", function()
  cosock_sleeps = {}
  local expected = { power = true, mode = 2, ["favorite-level"] = 7 }
  local device, emitted = optimistic_fixture("airp", expected, { expected })
  command_handlers.set_favorite_level(nil, device, { args = { level = 7 } })
  assert(#emitted == 3)
  assert(emitted[1].capability == "earthpanel38939.airPurifierFavoriteLevel")
  assert(emitted[2].capability == "switch" and emitted[2].method == "on")
  assert(emitted[3].capability == "mode" and emitted[3].args[1] == "즐겨찾기")
end)

test("command confirmation retries once then accepts propagated state", function()
  cosock_sleeps = {}
  local expected = { power = true, ["speed-percent"] = 55 }
  local stale = { power = true, ["speed-percent"] = 20 }
  local device, _, state = optimistic_fixture("fan", expected, { stale, expected })
  command_handlers.set_fan_speed_percent(nil, device, { args = { percent = 55 } })
  assert(#cosock_sleeps == 2)
  assert(cosock_sleeps[1] == 0.5 and cosock_sleeps[2] == 1.5)
  assert(#state.applied == 1 and state.applied[1]["speed-percent"] == 55)
  assert(state.online and not state.offline)
end)

test("command confirmation mismatch rolls UI back to actual state", function()
  cosock_sleeps = {}
  local expected = { power = true, ["speed-percent"] = 55 }
  local actual = { power = true, ["speed-percent"] = 20 }
  local device, _, state = optimistic_fixture("fan", expected, { actual, actual })
  command_handlers.set_fan_speed_percent(nil, device, { args = { percent = 55 } })
  assert(#state.applied == 1 and state.applied[1]["speed-percent"] == 20)
  assert(state.online and not state.offline)
end)

test("air purifier setters use expected MiOT properties", function()
  local client, calls = recording_client()
  assert(airp.set_mode(client, "수면"))
  assert(calls[1].siid == 2 and calls[1].piid == 4 and calls[1].value == 1)
  assert(airp.set_indicator(client, "bright"))
  assert(calls[2].siid == 13 and calls[2].piid == 2 and calls[2].value == 2)
  assert(airp.set_favorite_level(client, 14))
  assert(calls[3].siid == 2 and calls[3].piid == 1 and calls[3].value == true)
  assert(calls[4].siid == 2 and calls[4].piid == 4 and calls[4].value == 2)
  assert(calls[5].siid == 9 and calls[5].piid == 11 and calls[5].value == 14)
  assert(airp.reset_filter(client))
  assert(calls[6].siid == 4 and calls[6].aiid == 1 and calls[6].args[1] == 0)
end)

test("dehumidifier setters use expected MiOT properties", function()
  local client, calls = recording_client()
  assert(dehumidifier.set_target_humidity(client, 55))
  assert(calls[1].siid == 2 and calls[1].piid == 5 and calls[1].value == 55)
  assert(dehumidifier.set_mode(client, "옷 건조"))
  assert(calls[2].siid == 2 and calls[2].piid == 3 and calls[2].value == 2)
  assert(dehumidifier.reset_filter(client))
  assert(calls[3].siid == 7 and calls[3].aiid == 3 and #calls[3].args == 0)
end)

local function refresh_fixture(results)
  local state = { online = false, offline = false, applied = false }
  local handler = {
    refresh_props = { { siid = 2, piid = 1, did = "power" } },
    apply_state = function(_, values)
      state.applied = true
      state.values = values
    end,
  }
  local client = {
    begin_session = function() return { dev_id = 1, base_stamp = 1, base_time = 1 } end,
    get_properties = function() return results end,
  }
  local device = {
    label = "test device",
    get_field = function(_, key)
      if key == "handler_module" then return handler end
      if key == "client" then return client end
    end,
    online = function() state.online = true end,
    offline = function() state.offline = true end,
  }
  return device, state
end

test("refresh marks all-error MiOT response offline", function()
  local device, state = refresh_fixture({ { did = "power", code = -9999 } })
  command_handlers.refresh(nil, device)
  assert(state.offline == true)
  assert(state.online == false)
  assert(state.applied == false)
end)

test("refresh applies successful MiOT properties", function()
  local device, state = refresh_fixture({ { did = "power", code = 0, value = true } })
  command_handlers.refresh(nil, device)
  assert(state.online == true)
  assert(state.offline == false)
  assert(state.applied == true)
  assert(state.values.power == true)
end)

local FAULT_CAP = "earthpanel38939.deviceFault"
local FILTER_CAP = "earthpanel38939.filterAlert"
local function alert_device(cache, supported)
  cache = cache or {}
  local emitted = {}
  local device = {
    log = { warn = function() end },
    supports_capability = function(_, cap)
      return not supported or supported[cap.ID] == true
    end,
    get_latest_state = function(_, component, cap, attribute)
      assert(component == "main")
      return cache[cap .. "." .. attribute]
    end,
    emit_event = function(_, event)
      emitted[#emitted + 1] = event
      local value = event.args[1]
      cache[event.capability .. "." .. event.attribute] =
        type(value) == "table" and value.value or value
    end,
  }
  return device, emitted, cache
end

test("water full emits once, clears, and alerts again on recurrence", function()
  local device, emitted = alert_device()
  dehumidifier.apply_state(device, { fault = 0 })
  dehumidifier.apply_state(device, { fault = 1 })
  for _ = 1, 100 do dehumidifier.apply_state(device, { fault = 1 }) end
  assert(#emitted == 2 and emitted[2].args[1] == "waterFull")
  dehumidifier.apply_state(device, { fault = 0 })
  dehumidifier.apply_state(device, { fault = 1 })
  assert(#emitted == 4 and emitted[4].args[1] == "waterFull")
end)

test("all known device faults preserve their distinct state", function()
  local device, emitted = alert_device()
  local expected = { [0] = "noFault", "waterFull", "sensorFault1", "sensorFault2",
    "commFault1", "filterClean", "defrost", "fanMotor", "overload", "lackOfRefrigerant" }
  for code = 0, 9 do
    dehumidifier.apply_state(device, { fault = code })
    assert(emitted[#emitted].args[1] == expected[code])
  end
  for _, entry in ipairs({ {0, "noFault"}, {2, "motorStuck"}, {3, "sensorLost"} }) do
    airp.apply_state(device, { fault = entry[1] })
    assert(emitted[#emitted].args[1] == entry[2])
  end
end)

test("missing and unknown faults cannot clear an active warning", function()
  local device, emitted, cache = alert_device()
  dehumidifier.apply_state(device, { fault = 1 })
  for _, handler in ipairs({dehumidifier, airp}) do
    handler.apply_state(device, {})
    handler.apply_state(device, { fault = 999 })
    handler.apply_state(device, { fault = "0" })
  end
  assert(#emitted == 1 and cache[FAULT_CAP .. ".fault"] == "waterFull")
end)

test("SDK restored state suppresses duplicate fault after restart", function()
  local device, _, cache = alert_device()
  dehumidifier.apply_state(device, { fault = 5 })
  local restarted = alert_device(cache)
  dehumidifier.on_init(restarted)
  local before = cache[FAULT_CAP .. ".fault"]
  local faults = 0
  restarted.emit_event = function(_, event)
    if event.capability == FAULT_CAP then faults = faults + 1 end
  end
  dehumidifier.apply_state(restarted, { fault = 5 })
  assert(before == "filterClean" and faults == 0)
end)

test("profile change exposes fault without consuming a hidden event", function()
  local supported = {}
  local device, emitted = alert_device(nil, supported)
  airp.apply_state(device, { fault = 2 })
  assert(#emitted == 0)
  supported[FAULT_CAP] = true
  airp.apply_state(device, { fault = 2 })
  assert(#emitted == 1 and emitted[1].args[1] == "motorStuck")
end)

test("filter warning uses 10 percent threshold and 15 percent hysteresis", function()
  local device, emitted, cache = alert_device(nil, { [FILTER_CAP] = true })
  for _, life in ipairs({81, 11, 10, 9, 10, 11, 15}) do
    airp.apply_state(device, { ["filter-life"] = life })
  end
  assert(#emitted == 2 and cache[FILTER_CAP .. ".status"] == "replace")
  airp.apply_state(device, { ["filter-life"] = 16 })
  assert(#emitted == 3 and cache[FILTER_CAP .. ".status"] == "normal")
  airp.apply_state(device, { ["filter-life"] = 0 })
  assert(#emitted == 4 and cache[FILTER_CAP .. ".status"] == "replace")
end)

test("initial low filter alerts and invalid or partial reads preserve it", function()
  local device, emitted, cache = alert_device(nil, { [FILTER_CAP] = true })
  airp.apply_state(device, { ["filter-life"] = 10 })
  for _, life in ipairs({-1, 101, "80", false, math.huge, 0/0}) do
    airp.apply_state(device, { ["filter-life"] = life })
  end
  airp.apply_state(device, {})
  assert(#emitted == 1 and cache[FILTER_CAP .. ".status"] == "replace")
  local restarted, restart_events = alert_device(cache, { [FILTER_CAP] = true })
  airp.on_init(restarted)
  airp.apply_state(restarted, { ["filter-life"] = 12 })
  assert(#restart_events == 0 and cache[FILTER_CAP .. ".status"] == "replace")
  airp.apply_state(restarted, { ["filter-life"] = 100 })
  assert(#restart_events == 1 and cache[FILTER_CAP .. ".status"] == "normal")
end)

test("failed MiOT fault property never generates a false recovery", function()
  local device, emitted, cache = alert_device()
  dehumidifier.apply_state(device, { fault = 1 })
  device.label = "dehumidifier"
  device.online = function() end
  device.offline = function() end
  local client = {
    begin_session = function() return {} end,
    get_properties = function() return {
      {did = "fault", code = -9999, value = 0},
      {did = "humidity", code = 0, value = 60},
    } end,
  }
  device.get_field = function(_, key)
    if key == "handler_module" then return dehumidifier end
    if key == "client" then return client end
  end
  command_handlers.refresh_core(nil, device)
  assert(cache[FAULT_CAP .. ".fault"] == "waterFull")
  for i = 2, #emitted do assert(emitted[i].capability ~= FAULT_CAP) end
end)

test("existing devices migrate alert profiles on restart without recreation", function()
  local captured
  package.preload["st.driver"] = function()
    return function(_, config)
      captured = config
      return { run = function() end }
    end
  end
  dofile(root .. "/xiaomi-miio/src/init.lua")
  assert(captured and captured.lifecycle_handlers.init)
  local original_refresh = command_handlers.refresh
  command_handlers.refresh = function() return true end
  for _, model in ipairs(require "models") do
    for _, advanced in ipairs({false, true}) do
      local metadata
      local fields = {}
      local schedules = 0
      local device = alert_device()
      device.id = "existing-device"
      device.device_network_id = "existing-network-id"
      device.model = model.model
      device.preferences = {
        deviceIp = "192.168.1.2", deviceToken = string.rep("a", 32),
        showAdvanced = advanced,
      }
      device.log.info = function() end
      device.log.error = function() end
      device.set_field = function(_, key, value) fields[key] = value end
      device.get_field = function(_, key) return fields[key] end
      device.try_update_metadata = function(_, value) metadata = value end
      device.thread = { call_on_schedule = function() schedules = schedules + 1 end }
      captured.lifecycle_handlers.init({
        get_devices = function() return {} end,
        try_create_device = function() return true end,
      }, device)
      assert(metadata.profile == (advanced and model.advanced_profile or model.profile))
      assert(metadata.provisioning_state == "PROVISIONED")
      assert(device.id == "existing-device" and schedules == 2)
    end
  end
  command_handlers.refresh = original_refresh
end)

local alerts = require "alerts"
local function routed_alert_fixture()
  local endpoint, emitted = alert_device()
  endpoint.model = alerts.MODEL
  endpoint.online = function() end
  local devices = {endpoint}
  local creations = 0
  local driver = {
    get_devices = function() return devices end,
    try_create_device = function(_, metadata)
      assert(metadata.type == "LAN" and metadata.profile == alerts.PROFILE)
      creations = creations + 1
      return true
    end,
  }
  local function source(label, persisted)
    local device = alert_device()
    local fields = persisted or {}
    device.label = label
    device.get_field = function(_, key) return fields[key] end
    device.set_field = function(_, key, value, opts)
      if key:match("^xiaomi_alert_v1_") then assert(opts and opts.persist) end
      fields[key] = value
    end
    alerts.attach(driver, device)
    return device, fields
  end
  return driver, endpoint, emitted, source, devices, function() return creations end
end

test("different appliances record distinct history without routine triggers", function()
  local _, _, emitted, source = routed_alert_fixture()
  local derh = source("제습기")
  local purifier = source("공청기")
  dehumidifier.apply_state(derh, {fault = 1})
  airp.apply_state(purifier, {fault = 2, ["filter-life"] = 10})
  assert(#emitted == 3)
  assert(emitted[1].args[1]:match("제습기") and emitted[1].args[1]:match("물통"))
  assert(emitted[2].args[1]:match("공청기") and emitted[2].args[1]:match("필터"))
  assert(emitted[3].args[1]:match("모터"))
  for i = 1, 3 do
    assert(emitted[i].capability == "earthpanel38939.latestAlert")
    assert(emitted[i].args[2].state_change == true)
  end
end)

test("routed alerts suppress polling and restart duplicates then rearm", function()
  local _, _, emitted, source = routed_alert_fixture()
  local device, fields = source("제습기")
  dehumidifier.apply_state(device, {fault = 5})
  for _ = 1, 100 do dehumidifier.apply_state(device, {fault = 5}) end
  local restarted = source("제습기", fields)
  dehumidifier.apply_state(restarted, {fault = 5})
  assert(#emitted == 1)
  dehumidifier.apply_state(restarted, {fault = 0})
  dehumidifier.apply_state(restarted, {fault = 5})
  assert(#emitted == 2)
end)

test("normal and defrost do not send alerts but rearm the next fault", function()
  local _, _, emitted, source = routed_alert_fixture()
  local device = source("제습기")
  for _, fault in ipairs({0, 6, 0, 999}) do dehumidifier.apply_state(device, {fault = fault}) end
  assert(#emitted == 0)
  dehumidifier.apply_state(device, {fault = 1})
  dehumidifier.apply_state(device, {fault = 6})
  dehumidifier.apply_state(device, {fault = 1})
  assert(#emitted == 2)
end)

test("pending endpoint creation does not consume a real warning", function()
  local driver, endpoint, emitted, source, devices, creations = routed_alert_fixture()
  devices[1] = nil
  local device, fields = source("제습기")
  dehumidifier.apply_state(device, {fault = 1})
  dehumidifier.apply_state(device, {fault = 1})
  assert(creations() == 1 and fields.xiaomi_alert_v1_fault == nil)
  driver.xiaomi_alert_create_at = os.time() - 61
  dehumidifier.apply_state(device, {fault = 1})
  assert(creations() == 2)
  devices[1] = endpoint
  dehumidifier.apply_state(device, {fault = 1})
  assert(#emitted == 1 and fields.xiaomi_alert_v1_fault == "waterFull")
end)

test("endpoint emit failure retries without marking the warning delivered", function()
  local _, endpoint, emitted, source = routed_alert_fixture()
  local original = endpoint.emit_event
  endpoint.emit_event = function() error("temporary failure") end
  local device, fields = source("제습기")
  dehumidifier.apply_state(device, {fault = 1})
  assert(fields.xiaomi_alert_v1_fault == nil)
  endpoint.emit_event = original
  dehumidifier.apply_state(device, {fault = 1})
  assert(#emitted == 1 and fields.xiaomi_alert_v1_fault == "waterFull")
end)

test("healthy repeated reads retry asynchronous endpoint provisioning", function()
  local driver, _, emitted, source, devices, creations = routed_alert_fixture()
  devices[1] = nil
  local device = source("제습기")
  dehumidifier.apply_state(device, {fault = 0})
  assert(creations() == 1)
  driver.xiaomi_alert_create_at = os.time() - 61
  dehumidifier.apply_state(device, {fault = 0})
  assert(creations() == 2 and #emitted == 0)
end)

test("filter hysteresis survives hidden profiles and restored source fields", function()
  local _, _, emitted, source = routed_alert_fixture()
  local device, fields = source("공청기")
  device.supports_capability = function() return false end
  airp.apply_state(device, {["filter-life"] = 10})
  airp.apply_state(device, {["filter-life"] = 12})
  assert(fields.xiaomi_filter_alert_status == "replace" and #emitted == 1)
  local restarted = source("공청기", fields)
  airp.apply_state(restarted, {["filter-life"] = 15})
  assert(#emitted == 1)
  airp.apply_state(restarted, {["filter-life"] = 16})
  airp.apply_state(restarted, {["filter-life"] = 10})
  assert(#emitted == 2)
end)

test("test command records a request without changing physical alert state", function()
  local driver, endpoint, emitted, source = routed_alert_fixture()
  local device, fields = source("제습기")
  dehumidifier.apply_state(device, {fault = 1})
  alerts.send_test(driver, device)
  assert(#emitted == 1)
  alerts.send_test(driver, endpoint)
  alerts.send_test(driver, endpoint)
  assert(#emitted == 3 and emitted[2].args[1]:match("테스트"))
  assert(fields.xiaomi_alert_v1_fault == "waterFull")
  dehumidifier.apply_state(device, {fault = 1})
  assert(#emitted == 3)
end)

test("alert endpoint initialization never sends a button push", function()
  local driver, endpoint, emitted = routed_alert_fixture()
  alerts.initialize(driver, endpoint)
  alerts.initialize(driver, endpoint)
  for _, event in ipairs(emitted) do assert(event.attribute ~= "button") end
end)

test("direct mode retains messages without firing the legacy routine", function()
  local driver, endpoint, emitted, source = routed_alert_fixture()
  local device = source("제습기")
  dehumidifier.apply_state(device, {fault = 1})
  alerts.send_test(driver, endpoint)
  assert(#emitted == 2)
  assert(emitted[1].args[1]:match("물통"))
  assert(emitted[2].args[1] == "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.")
  for _, event in ipairs(emitted) do assert(event.capability ~= "button") end
end)

test("purifier keeps its saved favorite setting while powered off", function()
  local emitted = {}
  local device = { emit_event = function(_, event) emitted[event.capability] = event end }
  airp.apply_state(device, {power = false, ["favorite-level"] = 14})
  assert(emitted["earthpanel38939.airPurifierFavoriteLevel"].args[1] == 14)
end)

test("compact rotation mirrors confirmed hardware state", function()
  local emitted = {}
  local device = { emit_event = function(_, event) emitted[event.capability] = event end }
  fan.apply_state(device, {swing = true})
  assert(emitted.fanOscillationMode.args[1] == "horizontal")
  assert(emitted["earthpanel38939.fanOscillationControl"].args[1] == "horizontal")
  fan.apply_state(device, {swing = false})
  assert(emitted["earthpanel38939.fanOscillationControl"].args[1] == "fixed")
end)

test("compact humidity mirrors the sensor without replacing standard history", function()
  local emitted = {}
  local device = { emit_event = function(_, event) emitted[event.capability] = event end }
  dehumidifier.apply_state(device, {humidity = 57})
  assert(emitted.relativeHumidityMeasurement.args[1] == 57)
  assert(emitted["earthpanel38939.currentHumidity"].args[1] == 57)
  emitted = {}
  device.supports_capability = function(_, cap) return cap.ID ~= "earthpanel38939.currentHumidity" end
  dehumidifier.apply_state(device, {humidity = 58})
  assert(emitted.relativeHumidityMeasurement.args[1] == 58)
  assert(not emitted["earthpanel38939.currentHumidity"], "old profiles must not receive unsupported events")
end)

test("humidity refuses drying mode or an unreadable mode without a write", function()
  for _, reply in ipairs({ { code = 0, value = 2 }, { code = -1 }, { code = 0, value = 9 } }) do
    local client, calls = recording_client()
    client.get_properties = function() reply.did = "mode"; return { reply } end
    assert(not dehumidifier.set_target_humidity(client, 60))
    assert(#calls == 0)
  end
  local client, calls = recording_client()
  client.get_properties = function() return nil, "timeout" end
  assert(not dehumidifier.set_target_humidity(client, 60) and #calls == 0)
end)

test("humidity accepts manual limits in smart and sleep modes", function()
  for _, mode in ipairs({0, 1}) do
    local client, calls = recording_client()
    client.get_properties = function() return { {did = "mode", code = 0, value = mode} } end
    for _, humidity in ipairs({40, 55, 70}) do
      assert(dehumidifier.set_target_humidity(client, humidity))
      assert(calls[#calls].value == humidity)
    end
    for _, humidity in ipairs({30, 39, 71, 55.5, "bad", math.huge}) do
      assert(not dehumidifier.set_target_humidity(client, humidity))
    end
    assert(#calls == 3)
  end
end)

test("dehumidifier timer supports twelve hours and cancel without changing power", function()
  local client, calls = recording_client()
  assert(dehumidifier.set_power_off_timer(client, 720))
  assert(calls[1].siid == 8 and calls[1].piid == 1 and calls[1].value == true)
  assert(calls[2].piid == 2 and calls[2].value == 720)
  assert(dehumidifier.set_power_off_timer(client, 0))
  assert(calls[3].siid == 8 and calls[3].value == false)
  assert(not dehumidifier.set_power_off_timer(client, 721) and #calls == 3)
end)

test("failed timer duration cancels a newly enabled default timer", function()
  local client, calls = recording_client()
  local setter = client.set_property
  client.set_property = function(self, siid, piid, value, did)
    setter(self, siid, piid, value, did)
    if piid == 2 then return nil, "timeout" end
    return true
  end
  assert(not dehumidifier.set_power_off_timer(client, 60))
  assert(#calls == 3 and calls[3].piid == 1 and calls[3].value == false)
end)

test("drying remaining seconds and standby timer minutes stay distinct", function()
  local emitted = {}
  local device = {emit_event = function(_, event) emitted[event.attribute] = event.args[1] end}
  dehumidifier.apply_state(device, { ["dry-after-off"] = true,
    ["dry-left-seconds"] = 2399, ["timer-enabled"] = true,
    ["timer-remaining"] = 120, ["warming-up"] = false })
  assert(emitted.remainingMinutes.value == 40 and emitted.minutes.value == 120)
  assert(emitted.dryAfterOff == "on" and emitted.warmingUp == "no")
  dehumidifier.apply_state(device, { ["timer-enabled"] = false, ["timer-remaining"] = 120 })
  assert(emitted.minutes.value == 0)
  local client, calls = recording_client()
  assert(dehumidifier.set_dry_after_off(client, "off"))
  assert(calls[1].siid == 7 and calls[1].piid == 1 and calls[1].value == false)
end)

test("fan manual timer limit and invalid controls do not send writes", function()
  local client, calls = recording_client()
  assert(fan.set_power_off_timer(client, 480) and calls[1].value == 28800)
  assert(not fan.set_power_off_timer(client, 481))
  assert(not fan.set_fan_speed_percent(client, "bad"))
  assert(not fan.set_oscillation_mode(client, "vertical"))
  assert(not fan.set_oscillation_angle(client, 121))
  assert(#calls == 1)
end)

test("purifier zero is a valid saved manual level not power off", function()
  local client, calls = recording_client()
  assert(airp.set_favorite_level(client, 0))
  assert(calls[1].value == true and calls[2].value == 2 and calls[3].value == 0)
  assert(not airp.set_favorite_level(client, -1) and #calls == 3)
end)

test("purifier filter reset requires verified standby", function()
  for _, reply in ipairs({{code = 0, value = true}, {code = -1}}) do
    local client, calls = recording_client()
    client.get_properties = function() reply.did = "power"; return {reply} end
    assert(not airp.reset_filter(client) and #calls == 0)
  end
end)

test("countdown confirmation accepts elapsed seconds but retries an increase", function()
  for _, actual in ipairs({58, 61}) do
    cosock_sleeps = {}
    local device = optimistic_fixture("fan", { ["power-off-delay"] = 60 },
      {{ ["power-off-delay"] = actual }, { ["power-off-delay"] = 58 }})
    local handler = device:get_field("handler_module")
    handler.confirmation_tolerances = fan.confirmation_tolerances
    handler.set_power_off_timer = function() return true, nil, { ["power-off-delay"] = 60 } end
    command_handlers.set_power_off_timer(nil, device, {args = {minutes = 1}})
    assert(#cosock_sleeps == (actual == 58 and 1 or 2))
  end
end)

test("timer survives firmware enable resetting duration to one hour", function()
  local state = { enabled = false, minutes = 0 }
  local client = {
    get_properties = function() return {{did = "timer-enabled", code = 0, value = state.enabled}} end,
    set_property = function(_, _, piid, value)
      if piid == 1 then
        state.enabled = value
        if value then state.minutes = 60 end
      else state.minutes = value end
      return true
    end,
  }
  assert(dehumidifier.set_power_off_timer(client, 720))
  assert(state.enabled and state.minutes == 720)
  assert(dehumidifier.set_power_off_timer(client, 120))
  assert(state.enabled and state.minutes == 120)
end)

test("target controls follow confirmed mode without guessing its humidity", function()
  for _, mode in ipairs({0, 1, 2, 9}) do
    local emitted = {}
    dehumidifier.apply_state({emit_event = function(_, event)
      emitted[event.attribute] = event.args[1]
    end}, {mode = mode, target = 50})
    assert(emitted.adjustable == ((mode == 0 or mode == 1) and "yes" or "no"))
    assert(emitted.targetHumidity.value == 50)
  end
end)

test("dehumidifier timer command uses its twelve hour capability", function()
  local device, emitted = optimistic_fixture("derh", { ["timer-enabled"] = true },
    {{ ["timer-enabled"] = true }})
  local handler = device:get_field("handler_module")
  handler.timer_capability = dehumidifier.timer_capability
  handler.set_power_off_timer = function() return true, nil, { ["timer-enabled"] = true } end
  command_handlers.set_power_off_timer(nil, device, {args = {minutes = 720}})
  assert(emitted[1].capability == "earthpanel38939.dehumidifierTimer")
  assert(emitted[1].args[1].value == 720)
end)

test("a cancel waits for an earlier slow timer command to finish", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local worker, requests = nil, {}
  local current = 0
  local device = optimistic_fixture("derh", { ["timer-minutes"] = 720 }, {{ ["timer-minutes"] = 720 }})
  local handler, client = device:get_field("handler_module"), device:get_field("client")
  handler.set_power_off_timer = function(_, minutes)
    requests[#requests + 1] = minutes
    if minutes == 720 then coroutine.yield() end
    current = minutes
    return true, nil, { ["timer-minutes"] = minutes }
  end
  client.get_properties = function() return {{did = "timer-minutes", code = 0, value = current}} end
  cosock.spawn = function(fn) worker = coroutine.create(fn); assert(coroutine.resume(worker)) end
  command_handlers.set_power_off_timer(nil, device, {args = {minutes = 720}})
  command_handlers.set_power_off_timer(nil, device, {args = {minutes = 0}})
  assert(#requests == 1, "cancel must not race the earlier write")
  assert(coroutine.resume(worker))
  cosock.spawn = original_spawn
  assert(#requests == 2 and requests[2] == 0 and current == 0)
end)

test("poll started before a command cannot roll back confirmed state", function()
  local device, _, state = optimistic_fixture("fan", {power = true}, {{power = true}})
  local handler, client = device:get_field("handler_module"), device:get_field("client")
  handler.set_switch = function() return true, nil, {power = true} end
  local first = true
  client.get_properties = function()
    if first then
      first = false; coroutine.yield()
      return {{did = "power", code = 0, value = false}}
    end
    return {{did = "power", code = 0, value = true}}
  end
  local poll = coroutine.create(function() command_handlers.refresh_core(nil, device) end)
  assert(coroutine.resume(poll))
  command_handlers.switch_on(nil, device)
  assert(coroutine.resume(poll))
  assert(#state.applied == 1 and state.applied[1].power == true)
end)

test("known appliance identity prevents wrong-device writes after IP or token changes", function()
  for _, did in ipairs({0, -1, 0xFFFFFFFF, 1.5, "123", math.huge, 0/0}) do
    assert(not Client.new{ip = "192.168.1.2", token = string.rep("ab", 16), expected_did = did})
  end
  local function rpc_count(sockets)
    local count = 0
    for _, sock in ipairs(sockets) do
      assert(sock.closed)
      for _, raw in ipairs(sock.sent) do if #raw > 32 then count = count + 1 end end
    end
    return count
  end
  local client, sockets = transport_fixture({expected_did = 123}, {
    {raw = client_hello(456)}, {raw = client_hello(456)}, {raw = client_hello(456)},
  })
  local ok, err = client:set_property(2, 1, false, "power")
  assert(not ok and err == "device identity changed" and rpc_count(sockets) == 0)
  -- The first set reached the intended appliance and lost its ACK. Even a
  -- correctly encrypted response from the same address cannot move its retry.
  client, sockets = transport_fixture({expected_did = 123}, {
    {raw = client_hello(123)}, {delay = 3},
    {raw = client_hello(456)}, {raw = client_hello(456)},
  })
  ok, err = client:set_property(2, 1, true, "power")
  assert(not ok and rpc_count(sockets) == 1)
  client, sockets = transport_fixture({expected_did = 123}, {
    {raw = client_hello(456)}, {raw = client_hello(456)},
  })
  assert(not client:send_raw('{"id":1}', {dev_id = 456, base_stamp = 100, base_time = os.time()}))
  assert(rpc_count(sockets) == 0, "a caller-supplied session must not override stored identity")
  client = transport_fixture({}, {
    {raw = client_hello(456)}, {raw = client_reply(456, '{"id":1,"result":[{"did":"power","code":0}]}')},
  })
  assert(client:set_property(2, 1, false, "power"), "manual connection without a known DID remains supported")
end)

test("MiOT read results match requested identities and retain valid partial reads", function()
  local props = {{siid = 2, piid = 1, did = "power"}, {siid = 2, piid = 3, did = "swing"}}
  local function read(body)
    local client = assert(Client.new{ip = "192.168.1.2", token = string.rep("ab", 16)})
    client.send_raw = function() return body end
    return client:get_properties(props)
  end
  for _, body in ipairs({
    '{"id":1,"result":[{"code":0,"value":true}]}',
    '{"id":1,"result":[{"did":"foreign","code":0,"value":true}]}',
    '{"id":1,"result":[{"did":"power","code":0,"value":true},{"did":"power","code":0,"value":false}]}',
    '{"id":1,"result":[{"did":"power","siid":3,"code":0,"value":true}]}',
    '{"id":1,"result":[{"did":"power","piid":2,"code":0,"value":true}]}',
    '{"id":1,"result":[{"did":"power","code":0}]}',
    '{"id":1,"result":[{"did":"power","code":0,"value":null}]}',
    '{"id":1,"result":[{"did":"power","code":0,"value":{}}]}',
    '{"id":1,"result":[{"did":"power","code":0,"value":1e999}]}',
  }) do
    local result, err = read(body)
    assert(not result and err, body)
  end
  local result = assert(read('{"id":1,"result":[{"did":"power","siid":2,"piid":1,"code":0,"value":false}]}'))
  assert(#result == 1 and result[1].value == false, "omitted properties must not discard a useful partial read")
  result = assert(read('{"id":1,"result":[{"did":"power","code":0,"value":false},{"did":"swing","code":-9999}]}'))
  assert(result[1].value == false and result[2].code == -9999)
end)

test("MiOT writes and actions require the requested result identity", function()
  local function client_with(body)
    local client = assert(Client.new{ip = "192.168.1.2", token = string.rep("ab", 16)})
    client.send_raw = function() return body end
    return client
  end
  for _, reply in ipairs({'{"code":0}', '{"did":"foreign","code":0}',
    '{"did":"power","siid":3,"code":0}', '{"did":"power","piid":3,"code":0}'}) do
    local ok, err = client_with('{"id":1,"result":[' .. reply .. ']}'):set_property(2, 1, true, "power")
    assert(not ok and err)
  end
  for _, reply in ipairs({'{"code":0}', '{"did":"foreign","code":0}',
    '{"did":"reset-filter","aiid":2,"code":0}'}) do
    local ok, err = client_with('{"id":1,"result":[' .. reply .. ']}'):action(4, 1, {}, "reset-filter")
    assert(not ok and err)
  end
  assert(client_with('{"id":1,"result":[{"did":"power","siid":2,"piid":1,"code":0}]}'):set_property(2, 1, false, "power"))
end)

test("partial operating state cannot publish saved fan speed or inactive timer duration", function()
  local emitted = {}
  local device = {emit_event = function(_, event) emitted[#emitted + 1] = event end}
  fan.apply_state(device, {["speed-percent"] = 55})
  dehumidifier.apply_state(device, {["timer-remaining"] = 120})
  assert(#emitted == 0, "saved values alone do not establish running state")
  fan.apply_state(device, {power = false})
  assert(emitted[#emitted].capability == "fanSpeedPercent" and emitted[#emitted].args[1] == 0)
  emitted = {}
  fan.apply_state(device, {power = true, ["speed-percent"] = 55})
  assert(emitted[#emitted].args[1] == 55)
  dehumidifier.apply_state(device, {["timer-enabled"] = true, ["timer-remaining"] = 120})
  assert(emitted[#emitted].args[1].value == 120)
end)

test("invalid property values do not contaminate successful partial Xiaomi reads", function()
  local emitted, online = {}, false
  local client = {begin_session = function() return {} end, get_properties = function(_, props)
    local result = {}
    for _, prop in ipairs(props) do
      result[#result + 1] = {did = prop.did, code = 0,
        value = prop.did == "humidity" and 57 or (prop.did == "power" and "false" or {})}
    end
    return result
  end}
  local device = {label = "fan", emit_event = function(_, event) emitted[#emitted + 1] = event end,
    get_field = function(_, key) return key == "handler_module" and fan or client end,
    online = function() online = true end, offline = function() error("valid humidity is still available") end}
  assert(command_handlers.refresh(nil, device) and online)
  assert(#emitted == 1 and emitted[1].attribute == "humidity" and emitted[1].args[1] == 57)
end)

test("partial confirmation without commanded properties cannot validate optimistic state", function()
  local device, _, state = optimistic_fixture("fan", {power = true, ["speed-percent"] = 55},
    {{["speed-percent"] = 55}, {["speed-percent"] = 55}})
  command_handlers.set_fan_speed_percent(nil, device, {args = {percent = 55}})
  assert(state.offline and not state.online, "missing power leaves the optimistic command unverified")
  assert(#state.applied == 1 and state.applied[1].power == nil)
end)

test("reattachment routes queued commands to the new client without replay or old readback", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local worker, calls, applied = nil, {}, {}
  local function client(name, value)
    return {name = name, begin_session = function() return {} end,
      get_properties = function() return {{did = "power", code = 0, value = value}} end}
  end
  local old, replacement = client("old", true), client("new", false)
  local fields = {client = old, handler_module = {refresh_props = {{siid = 2, piid = 1, did = "power"}},
    set_switch = function(c, value)
      calls[#calls + 1] = c.name .. ":" .. tostring(value)
      if #calls == 1 then coroutine.yield() end
      return true, nil, {power = value}
    end, apply_state = function(_, values) applied[#applied + 1] = values.power end}}
  local device = {label = "test", get_field = function(_, key) return fields[key] end,
    emit_event = function() end, online = function() end, offline = function() end}
  cosock.spawn = function(fn) worker = coroutine.create(fn); assert(coroutine.resume(worker)) end
  command_handlers.switch_on(nil, device)
  fields.client = replacement
  command_handlers.switch_off(nil, device)
  assert(coroutine.resume(worker))
  cosock.spawn = original_spawn
  assert(#calls == 2 and calls[1] == "old:true" and calls[2] == "new:false")
  assert(#applied == 1 and applied[1] == false)
end)

test("reattachment discards a poll or confirmation already awaiting old readback", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  for _, command in ipairs({false, true}) do
    local worker, applied = nil, 0
    local handler = {refresh_props = {{siid = 2, piid = 1, did = "power"}},
      set_switch = function() return true, nil, {power = true} end,
      apply_state = function() applied = applied + 1 end}
    local fields = {handler_module = handler, client = {
      begin_session = function() return {} end, get_properties = function()
        coroutine.yield(); return {{did = "power", code = 0, value = true}}
      end}}
    local device = {label = "test", get_field = function(_, key) return fields[key] end,
      emit_event = function() end, online = function() error("stale online result") end,
      offline = function() error("stale offline result") end}
    if command then
      cosock.spawn = function(fn) worker = coroutine.create(fn); assert(coroutine.resume(worker)) end
      command_handlers.switch_on(nil, device)
    else
      worker = coroutine.create(function() command_handlers.refresh(nil, device) end)
      assert(coroutine.resume(worker))
    end
    fields.client = {}
    assert(coroutine.resume(worker))
    assert(applied == 0)
  end
  cosock.spawn = original_spawn
end)

test("reattachment stops unsent follow-up RPCs in a compound Xiaomi setter", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local worker, writes = nil, {}
  local old = {set_property = function(_, _, _, value, did)
    writes[#writes + 1] = did
    if #writes == 1 then coroutine.yield() end
    return true
  end}
  local fields = {client = old, handler_module = fan}
  local device = {label = "fan", get_field = function(_, key) return fields[key] end,
    emit_event = function() end, online = function() end, offline = function() end}
  cosock.spawn = function(fn) worker = coroutine.create(fn); assert(coroutine.resume(worker)) end
  command_handlers.set_fan_speed_percent(nil, device, {args = {percent = 55}})
  fields.client = {}
  assert(coroutine.resume(worker))
  cosock.spawn = original_spawn
  assert(#writes == 1 and writes[1] == "power", "unsent speed write must not use superseded credentials")
end)

test("reattachment during publication suppresses remaining fan poll and confirmation events", function()
  for _, command in ipairs({false, true}) do
    local emitted, publishing, replacement = {}, false, {}
    local values = {power = true, ["speed-percent"] = 55, swing = true,
      ["fan-mode"] = 0, ["power-off-delay"] = 60}
    local client = {set_property = function() return true end, begin_session = function() return {} end,
      get_properties = function(_, props)
        local result = {}
        for _, prop in ipairs(props) do result[#result + 1] = {did = prop.did, code = 0, value = values[prop.did]} end
        return result
      end}
    local fields = {client = client, handler_module = fan}
    local device = {label = "fan", get_field = function(_, key) return fields[key] end,
      online = function() publishing = true end, offline = function() end,
      emit_event = function(_, event)
        if publishing then
          emitted[#emitted + 1] = event
          if #emitted == 1 then fields.client = replacement end
        end
      end}
    if command then command_handlers.switch_on(nil, device) else command_handlers.refresh_core(nil, device) end
    assert(#emitted == 1 and emitted[1].capability == "switch",
      "a callback replacing the attachment must suppress later old speed, mode, swing and timer events")
    assert(fields.client == replacement)
  end
end)

test("a new command during poll publication suppresses the rest of the older poll", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local workers, emitted, first = {}, {}, true
  local values = {power = true, ["speed-percent"] = 55, swing = true, ["fan-mode"] = 0, ["power-off-delay"] = 60}
  local client = {set_property = function() return true end, begin_session = function() return {} end,
    get_properties = function(_, props)
      local result = {}
      for _, prop in ipairs(props) do result[#result + 1] = {did = prop.did, code = 0, value = values[prop.did]} end
      return result
    end}
  local fields = {client = client, handler_module = fan}
  local device
  device = {label = "fan", get_field = function(_, key) return fields[key] end,
    online = function() end, offline = function() end, emit_event = function(_, event)
      emitted[#emitted + 1] = event
      if first then first = false; command_handlers.switch_off(nil, device) end
    end}
  cosock.spawn = function(fn) workers[#workers + 1] = fn end
  command_handlers.refresh_core(nil, device)
  cosock.spawn = original_spawn
  assert(#workers == 1 and #emitted == 3, "only the first poll event and two new optimistic events may publish")
  assert(emitted[1].method == "on" and emitted[2].method == "off" and emitted[3].args[1] == 0)
end)

test("reattachment during state publication suppresses stale persistent fields and alert history", function()
  local emitted, persisted, history, publishing = 0, 0, 0, false
  local values = {power = true, mode = 0, fault = 2, pm25 = 5, ["filter-life"] = 10, ["favorite-level"] = 3}
  local client = {begin_session = function() return {} end, get_properties = function(_, props)
    local result = {}
    for _, prop in ipairs(props) do result[#result + 1] = {did = prop.did, code = 0, value = values[prop.did]} end
    return result
  end}
  local fields = {client = client, handler_module = airp,
    xiaomi_alert_sink = function(message) if message then history = history + 1 end; return true end}
  local device = {label = "purifier", log = {warn = function() end},
    get_field = function(_, key) return fields[key] end,
    set_field = function(_, key, value) fields[key] = value; persisted = persisted + 1 end,
    online = function() publishing = true end, offline = function() end,
    emit_event = function()
      emitted = emitted + 1
      if publishing then fields.client = {} end
    end}
  command_handlers.refresh_core(nil, device)
  assert(emitted == 1 and persisted == 0 and history == 0,
    "old filter/fault reads must not persist latches or publish history after an event reconnects")
end)

test("reattachment during confirmation suppresses the previous command completion event", function()
  local capabilities = require "st.capabilities"
  local emitted, publishing = {}, false
  local handler = {uses_filter_maintenance = true, core_props = {{siid = 2, piid = 1, did = "power"}},
    reset_filter = function() return true, nil, {} end,
    apply_state = function(device)
      device:emit_event(capabilities.switch.switch.off())
      device:emit_event(capabilities.mode.mode("스마트"))
    end}
  local client = {begin_session = function() return {} end,
    get_properties = function() return {{did = "power", code = 0, value = false}} end}
  local fields = {handler_module = handler, client = client}
  local device = {label = "dehumidifier", get_field = function(_, key) return fields[key] end,
    online = function() publishing = true end, offline = function() end,
    emit_event = function(_, event)
      emitted[#emitted + 1] = event
      if publishing then fields.client = {} end
    end}
  command_handlers.reset_filter(nil, device)
  assert(#emitted == 2 and emitted[1].args[1] == "resetting" and emitted[2].method == "off",
    "the old reset task cannot publish its later mode or ready completion on the replacement attachment")
end)

test("reattachment inside alert endpoint publication cannot emit stale history or save its marker", function()
  local alerts = require "alerts"
  local history, fields = 0, {}
  local values = {power = true, mode = 0, fault = 2, pm25 = 5, ["filter-life"] = 10, ["favorite-level"] = 3}
  local client = {begin_session = function() return {} end, get_properties = function(_, props)
    local result = {}
    for _, prop in ipairs(props) do result[#result + 1] = {did = prop.did, code = 0, value = values[prop.did]} end
    return result
  end}
  fields.client, fields.handler_module = client, airp
  local device = {label = "purifier", log = {warn = function() end},
    get_field = function(_, key) return fields[key] end,
    set_field = function(_, key, value) fields[key] = value end,
    online = function() end, offline = function() end, emit_event = function() end}
  local endpoint = {model = alerts.MODEL, supports_capability = function()
    fields.client = {}; return true
  end, emit_event = function() history = history + 1 end}
  alerts.attach({get_devices = function() return {endpoint} end}, device)
  command_handlers.refresh_core(nil, device)
  assert(history == 0 and fields.xiaomi_alert_v1_filter == nil and fields.xiaomi_alert_v1_fault == nil,
    "a lifecycle change inside endpoint supports must be checked before its event and delivered marker")
end)

test("a new command during confirmation publication keeps its optimistic state", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local workers, emitted, publishing, requested = {}, {}, false, false
  local values = {power = true, ["speed-percent"] = 55, swing = true, ["fan-mode"] = 0}
  local client = {set_property = function(_, _, _, value) values.power = value; return true end,
    begin_session = function() return {} end, get_properties = function(_, props)
      local result = {}
      for _, prop in ipairs(props) do result[#result + 1] = {did = prop.did, code = 0, value = values[prop.did]} end
      return result
    end}
  local fields = {client = client, handler_module = fan}
  local device
  device = {label = "fan", get_field = function(_, key) return fields[key] end,
    online = function() publishing = true end, offline = function() end,
    emit_event = function(_, event)
      if not publishing then return end
      emitted[#emitted + 1] = event
      if not requested then
        requested = true
        command_handlers.switch_off(nil, device)
        coroutine.yield()
      end
    end}
  cosock.spawn = function(fn) workers[#workers + 1] = coroutine.create(fn); assert(coroutine.resume(workers[#workers])) end
  command_handlers.switch_on(nil, device)
  -- The first confirmed event queued a newer command. Let its optimistic
  -- events complete and suspend before the older apply_state continues.
  assert(#emitted == 3 and emitted[2].method == "off" and emitted[3].args[1] == 0)
  assert(coroutine.resume(workers[1]))
  cosock.spawn = original_spawn
  assert(#emitted == 8, "old confirmation must not add any events between the new optimistic and confirmed off state")
  assert(emitted[3].args[1] == 0 and emitted[4].method == "off" and emitted[5].args[1] == 0)
  for _, event in ipairs(emitted) do
    if event.capability == "fanSpeedPercent" then assert(event.args[1] == 0, "stale positive speed cannot overwrite cancel") end
  end
end)

test("a queued switch command does not suppress filter reset completion on the same attachment", function()
  local cosock = require "cosock"
  local original_spawn = cosock.spawn
  local worker, maintenance, power = nil, {}, false
  local handler = {uses_filter_maintenance = true, refresh_props = {{siid = 2, piid = 1, did = "power"}},
    reset_filter = function() coroutine.yield(); return true, nil, {} end,
    set_switch = function(_, value) power = value; return true, nil, {power = value} end,
    apply_state = function() end}
  local client = {begin_session = function() return {} end,
    get_properties = function() return {{did = "power", code = 0, value = power}} end}
  local fields = {handler_module = handler, client = client}
  local device = {label = "dehumidifier", get_field = function(_, key) return fields[key] end,
    online = function() end, offline = function() end, emit_event = function(_, event)
      if event.capability == "earthpanel38939.filterMaintenance" then maintenance[#maintenance + 1] = event.args[1] end
    end}
  cosock.spawn = function(fn) worker = coroutine.create(fn); assert(coroutine.resume(worker)) end
  command_handlers.reset_filter(nil, device)
  command_handlers.switch_on(nil, device)
  assert(coroutine.resume(worker))
  cosock.spawn = original_spawn
  assert(power and #maintenance == 2 and maintenance[1] == "resetting" and maintenance[2] == "ready",
    "an unrelated queued command must not leave completed maintenance stuck resetting")
end)

print(string.format("%d tests passed", passed))
