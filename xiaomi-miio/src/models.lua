--[[
  Catalog of supported Xiaomi MiOT models. Discovery uses this list to spawn
  one SmartThings device record per model on first scan-nearby. The user then
  enters the device's IP and token in the device settings.
]]

return {
  {
    handler = "fan_za5",
    model   = "zhimi.fan.za5",
    profile = "xiaomi-fan-za5.v1",
    label   = "Xiaomi Fan",
    vendor_label = "Mi Smart Standing Fan 2",
  },
  {
    handler = "airp_cpa4",
    model   = "zhimi.airp.cpa4",
    profile = "xiaomi-airp-cpa4.v1",
    label   = "Xiaomi Air Purifier",
    vendor_label = "Mi Air Purifier 4 Compact",
  },
  {
    handler = "derh_13l",
    model   = "xiaomi.derh.13l",
    profile = "xiaomi-derh-13l.v1",
    label   = "Xiaomi Dehumidifier",
    vendor_label = "Xiaomi Smart Dehumidifier 13L",
  },
}
