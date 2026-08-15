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

return M
