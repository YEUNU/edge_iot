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
  assert(#dehumidifier.core_props == 5 and #dehumidifier.aux_props == 4)
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

print(string.format("%d tests passed", passed))
