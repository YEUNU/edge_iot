--[[
  Tuya virtual AC (category infrared_ac) ↔ SmartThings capability mapping.

  Command codes (sent via /devices/{id}/commands):
    switch  bool
    mode    enum  ("cold" | "heat" | "auto" | "dehumidification" | "wind_dry")
    temp    int 16..30
    fan     enum  ("low" | "mid" | "high" | "auto")

  Status codes (returned by /devices/{id}/status — all integer-as-string):
    power   "0" / "1"
    mode    "0".."4"
    temp    "16".."30"
    wind    "0".."3"

  The integer-to-name mapping below follows the order in functions.values.range
  for this product. If a future device reports the modes in a different order
  the driver will mis-label them; in that case update STATUS_MODE_TO_TUYA.
]]

local M = {}

-- Tuya status integer (string) → Tuya command name
M.STATUS_MODE_TO_TUYA = {
  ["0"] = "dehumidification",
  ["1"] = "cold",
  ["2"] = "auto",
  ["3"] = "wind_dry",
  ["4"] = "heat",
}

M.STATUS_FAN_TO_TUYA = {
  ["0"] = "low",
  ["1"] = "mid",
  ["2"] = "high",
  ["3"] = "auto",
}

-- Tuya command name ↔ SmartThings airConditionerMode enum
M.TUYA_TO_ST_MODE = {
  cold              = "cool",
  heat              = "heat",
  auto              = "auto",
  dehumidification  = "dry",
  wind_dry          = "fanOnly",
}
M.ST_TO_TUYA_MODE = {}
for tuya, st in pairs(M.TUYA_TO_ST_MODE) do M.ST_TO_TUYA_MODE[st] = tuya end

M.SUPPORTED_ST_MODES = { "cool", "heat", "auto", "dry", "fanOnly" }

-- Tuya fan name ↔ SmartThings airConditionerFanMode enum
M.TUYA_TO_ST_FAN = {
  low  = "low",
  mid  = "medium",
  high = "high",
  auto = "auto",
}
M.ST_TO_TUYA_FAN = {}
for tuya, st in pairs(M.TUYA_TO_ST_FAN) do M.ST_TO_TUYA_FAN[st] = tuya end

M.SUPPORTED_ST_FANS = { "auto", "low", "medium", "high" }

--- Convert a status list from Tuya into a flat lua table { power=bool, mode=tuya_name, temp=int, wind=tuya_name }.
function M.parse_status(status_list)
  local out = {}
  for _, p in ipairs(status_list or {}) do
    if p.code == "power" then
      out.power = (tostring(p.value) == "1")
    elseif p.code == "mode" then
      out.mode = M.STATUS_MODE_TO_TUYA[tostring(p.value)]
    elseif p.code == "temp" then
      out.temp = tonumber(p.value)
    elseif p.code == "wind" then
      out.wind = M.STATUS_FAN_TO_TUYA[tostring(p.value)]
    end
  end
  return out
end

return M
