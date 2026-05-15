# edge_iot — SmartThings Edge driver for Xiaomi (miIO/MiOT)

LAN-only SmartThings Edge driver that controls three Xiaomi devices over UDP/54321 using the miIO/MiOT protocol — no Xiaomi Cloud involved. Tokens are stored locally and used to derive AES-128-CBC key/IV (key = MD5(token), iv = MD5(key || token)) per device.

Supported devices (registered to specific IPs/tokens in `xiaomi-miio/src/devices_config.lua`):

| Device | MiOT model | Profile |
|---|---|---|
| Mi Smart Standing Fan 2 | `zhimi.fan.za5` | `xiaomi-fan-za5.v1` |
| Mi Air Purifier 4 Compact | `zhimi.airp.cpa4` | `xiaomi-airp-cpa4.v1` |
| Xiaomi Smart Dehumidifier 13L | `xiaomi.derh.13l` | `xiaomi-derh-13l.v1` |

## Project layout

```
xiaomi-miio/
├── config.yml              # driver metadata (name, packageKey, lan permission)
├── profiles/               # one SmartThings profile per device model
│   ├── xiaomi-fan-za5.yml
│   ├── xiaomi-airp-cpa4.yml
│   └── xiaomi-derh-13l.yml
└── src/
    ├── init.lua            # driver entry: lifecycle, capability handlers
    ├── discovery.lua       # iterates devices_config and registers each
    ├── command_handlers.lua# routes ST commands → device handler module
    ├── devices_config.lua  # IPs + tokens (sensitive)
    ├── miio/
    │   ├── md5.lua         # pure-Lua MD5 (RFC 1321)
    │   ├── aes.lua         # pure-Lua AES-128-CBC + PKCS#7 (FIPS 197)
    │   ├── packet.lua      # miIO 32-byte header + encrypted payload
    │   └── client.lua      # high-level handshake/get/set/action RPC
    └── devices/
        ├── fan_za5.lua     # MiOT siid/piid ↔ ST capability mapping
        ├── airp_cpa4.lua
        └── derh_13l.lua
```

## Capability coverage (v1)

| Device | switch | mode | fanSpeed | humidity | temp | PM2.5 / AQI | filter |
|---|---|---|---|---|---|---|---|
| Fan      | ✓ | Natural / Straight | 0..4 | ✓ | ✓ | – | – |
| Air Purifier | ✓ | Auto / Sleep / Favorite | – | – | – | ✓ (dustSensor + airQualitySensor) | ✓ |
| Dehumidifier | ✓ | Smart / Sleep / Drying | – | ✓ | ✓ | – | – |

Deferred (custom capabilities required): target humidity slider for the dehumidifier, oscillation/angle for the fan, child-lock, buzzer, indicator brightness, fault alerts.

## Prerequisites

- A SmartThings hub that supports Edge (Station / Aeotec v3 / newer).
- The [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) (`smartthings`) authenticated against your Samsung account.
- The hub and the three Xiaomi devices on the same LAN. Set static/reserved DHCP leases for the three MACs on your router so the IPs in `devices_config.lua` stay stable.

## Configure your devices

No source-code editing required. Each device's IP and token are read from the device's SmartThings settings panel (defined as `preferences` in the profile YAMLs). After the driver is installed:

1. In the SmartThings app, choose **Add device → Scan nearby** with your hub selected. The driver creates three placeholder devices: Xiaomi Fan, Xiaomi Air Purifier, Xiaomi Dehumidifier. Delete the ones you don't own.
2. Open each device → ⚙ Settings → enter:
   - **기기 IP 주소** — LAN IPv4 of the device (set a reserved DHCP lease on your router).
   - **기기 Token (32-hex)** — extract with [Xiaomi-Cloud-Tokens-Extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) (logs into your Mi Home account and prints token + IP per device).
3. Save. The driver picks up the new values via `infoChanged`, runs a first refresh, and starts the 60-second polling loop.

## Deploy

```bash
# 1) Sanity check the source tree (catches YAML / Lua typos)
smartthings edge:drivers:package xiaomi-miio --build-only

# 2) Create a private channel (one-time)
smartthings edge:channels:create
#   record the channel UUID from the output as $CHAN

# 3) Enroll the hub on the channel (one-time per hub)
smartthings edge:channels:enroll $CHAN

# 4) Publish the driver to the channel
smartthings edge:drivers:package xiaomi-miio
#   record the driver UUID as $DRV
smartthings edge:channels:assign $CHAN $DRV

# 5) Install the driver onto the hub
smartthings edge:drivers:install $DRV

# 6) Verify it is loaded and stream logs
smartthings edge:drivers:installed
smartthings edge:drivers:logcat $DRV --hub-address <hub-lan-ip>
```

In the SmartThings app: **Add device → Scan nearby** with the hub selected. The driver's discovery loop will iterate `devices_config.lua`, send a miIO Hello to each IP, and create the three devices that respond.

## Iterating

```bash
# After editing source, repackage and bump the version
smartthings edge:drivers:package xiaomi-miio
smartthings edge:channels:assign $CHAN $DRV
# Hub picks up the new version on its next sync (within ~12h) or:
smartthings edge:drivers:switch -H <hub-lan-ip>
```

## Security

`xiaomi-miio/src/devices_config.lua` contains plaintext device tokens. Do not push this file to a public repository. If you publish the driver, blank out the tokens or replace the file with an example version. The hub stores the driver in encrypted storage, so the tokens never leave your LAN.

## References

- SmartThings Edge driver examples: https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers (see `drivers/SmartThings/wemo` for a LAN/UDP-based driver pattern).
- miIO protocol reference: https://github.com/rytilahti/python-miio (`miio/miioprotocol.py`, `miio/protocol.py`).
- MiOT device specs (siid/piid): https://miot-spec.org/miot-spec-v2/instance?type=<urn> — JSON API used to generate the mappings in `src/devices/`.

## Test on the host (no hub required)

The miIO library can run under regular Lua 5.3+ with `luasocket`:

```bash
brew install lua luarocks
luarocks --lua-version 5.5 install luasocket dkjson

cd xiaomi-miio/src && lua -e '
package.path = "./?.lua;./miio/?.lua;" .. package.path
local Client = require "miio.client"
local c = Client.new{ ip = "192.168.1.4", token = "<32-hex-token>" }
local info, err = c:miio_info(); print(info and info.model or err)
'
```

This was used to validate the protocol implementation against the real devices before deploying.
