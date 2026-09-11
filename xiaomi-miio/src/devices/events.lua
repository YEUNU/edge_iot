-- Emit only capabilities included in the device's active profile. Host-side
-- tests use lightweight devices without supports_capability, so they retain
-- the previous behavior.
local M = {}

function M.supports(device, capability)
  if not capability then return false end
  if type(device.supports_capability) ~= "function" then return true end
  return device:supports_capability(capability)
end

function M.emit(device, capability, event)
  if event and M.supports(device, capability) then
    device:emit_event(event)
  end
end

-- The SDK keeps the latest emitted attribute state across driver restarts.
-- Only suppress after checking the active profile: a hidden capability must
-- still be populated when it becomes available after a profile update.
function M.emit_changed(device, capability, attribute, value, event)
  if not event or not M.supports(device, capability) then return false end
  if type(device.get_latest_state) == "function"
      and device:get_latest_state("main", capability.ID, attribute) == value then
    return false
  end
  device:emit_event(event)
  return true
end

return M
