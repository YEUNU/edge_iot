--[[
  Catalog of supported Xiaomi MiOT models. Discovery creates one generic setup
  device per scan; the selected model switches that record to the matching
  simple or advanced profile without recreating the device.
]]

return {
  {
    handler = "fan_za5",
    model   = "zhimi.fan.za5",
    profile = "xiaomi-fan-za5.v1",
    advanced_profile = "xiaomi-fan-za5.advanced.v1",
    label   = "Xiaomi Fan",
    vendor_label = "Mi Smart Standing Fan 2",
  },
  {
    handler = "airp_cpa4",
    model   = "zhimi.airp.cpa4",
    profile = "xiaomi-airp-cpa4.v1",
    advanced_profile = "xiaomi-airp-cpa4.advanced.v1",
    label   = "Xiaomi Air Purifier",
    vendor_label = "Mi Air Purifier 4 Compact",
  },
  {
    handler = "derh_13l",
    model   = "xiaomi.derh.13l",
    profile = "xiaomi-derh-13l.v1",
    advanced_profile = "xiaomi-derh-13l.advanced.v1",
    label   = "Xiaomi Dehumidifier",
    vendor_label = "Xiaomi Smart Dehumidifier 13L",
  },
}
