local M = {}

function M.integer(value, minimum, maximum)
  value = tonumber(value)
  if not value or value ~= value or value < minimum or value > maximum
      or value ~= math.floor(value) then
    return nil, string.format("expected an integer from %d to %d", minimum, maximum)
  end
  return value
end

function M.read(client, siid, piid, did)
  local result, err = client:get_properties({ { siid = siid, piid = piid, did = did } })
  if not result then return nil, err end
  for _, prop in ipairs(result) do
    if prop.did == did and tonumber(prop.code) == 0 and prop.value ~= nil then
      return prop.value
    end
  end
  return nil, "could not read " .. did
end

return M
