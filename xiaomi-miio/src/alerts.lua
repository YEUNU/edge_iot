-- Shared maintenance history and test requests. The Docker service delivers
-- per-device push messages from confirmed fault/filter attributes. This module
-- never triggers the legacy routine; a history event is not proof of delivery.
local capabilities = require "st.capabilities"
local log = require "log"
local M = { MODEL = "xiaomi.alerts", PROFILE = "xiaomi-alerts.v1" }
local cap_message = capabilities["earthpanel38939.latestAlert"]
local CREATE_RETRY_S = 60

function M.is_endpoint(device)
  return device.model == M.MODEL
end

function M.find(driver)
  for _, device in ipairs(driver:get_devices()) do
    if M.is_endpoint(device) then return device end
  end
end

function M.ensure(driver)
  local endpoint = M.find(driver)
  if endpoint then return endpoint end
  local now = os.time()
  if driver.xiaomi_alert_create_at and now - driver.xiaomi_alert_create_at < CREATE_RETRY_S then
    return nil
  end
  -- Guard before sending: several physical devices can initialize concurrently.
  driver.xiaomi_alert_create_at = now
  local ok, err = driver:try_create_device({
    type = "LAN", device_network_id = "xiaomi-maintenance-alerts-v1",
    label = "Xiaomi 알림", profile = M.PROFILE, manufacturer = "Xiaomi",
    model = M.MODEL, vendor_provided_label = "Xiaomi 알림",
  })
  if not ok then log.warn("could not create Xiaomi alert endpoint: " .. tostring(err)) end
  -- Creation is asynchronous. A later poll retries any pending warning.
  return nil
end

function M.initialize(_, device)
  device:online()
  if cap_message and not device:get_latest_state("main", cap_message.ID, "message") then
    device:emit_event(cap_message.message("기기별 직접 알림을 사용합니다. 테스트 알림으로 연결을 확인하세요."))
  end
end

function M.emit(endpoint, message)
  if not cap_message or not endpoint:supports_capability(cap_message) then
    return false
  end
  endpoint:emit_event(cap_message.message(message, { state_change = true }))
  return true
end

function M.attach(driver, device)
  M.ensure(driver)
  device:set_field("xiaomi_alert_sink", function(message)
    local endpoint = M.ensure(driver)
    if not message then return endpoint ~= nil end
    return endpoint and M.emit(endpoint, message) or false
  end)
end

function M.report(device, key, value, message)
  if type(device.get_field) ~= "function" or type(device.set_field) ~= "function" then return end
  local sink = device:get_field("xiaomi_alert_sink")
  -- Retry endpoint provisioning even when every appliance stays healthy.
  -- A nil message only checks availability; it never emits a button event.
  if sink then pcall(sink) end
  local field = "xiaomi_alert_v1_" .. key
  if device:get_field(field) == value then return end
  if message then
    if not sink then return end
    local body = (device.label or "Xiaomi 기기") .. ": " .. message
    local ok, emitted = pcall(sink, body)
    if not ok then log.warn("Xiaomi alert emission failed; retrying on next confirmed read") end
    if not ok or not emitted then return end
  end
  -- Mark history recorded only after the endpoint accepts it. The companion
  -- independently persists actual push acceptance, not this history marker.
  -- Healthy states rearm the next occurrence without emitting a notification.
  device:set_field(field, value, { persist = true })
end

function M.send_test(_, device)
  if not M.is_endpoint(device) then return end
  M.emit(device, "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.")
end

return M
