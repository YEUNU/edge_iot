# edge_iot — SmartThings Edge driver

SmartThings Edge drivers for Xiaomi MiIO/MiOT devices and Tuya IR air conditioners, with local control paths.

## Xiaomi MiIO LAN

The primary driver controls three Xiaomi models directly over UDP/54321. It
does not use Xiaomi Cloud for control. A one-time QR login helper can retrieve
tokens during onboarding and transfer them to the hub. Per-device tokens are
stored in hub fields (or manual preferences) and derive the MiIO AES-128-CBC key and IV.

| Device | MiOT model | Main capabilities |
|---|---|---|
| Mi Smart Standing Fan 2 | `zhimi.fan.za5` | Power, speed, oscillation, wind mode, off timer |
| Mi Air Purifier 4 Compact | `zhimi.airp.cpa4` | Power, mode, PM2.5, favorite level, filter life |
| Xiaomi Smart Dehumidifier 13L | `xiaomi.derh.13l` | Power, mode, current/target humidity, fault status |

### Local discovery

The hub now scans miIO locally at startup, every five minutes, and on nearby
scan. Refresh on the Xiaomi setup device also starts a scan. Existing tokens
are reused; authenticated discovered addresses are stored on the hub. Devices
that expose a usable local token can be enrolled automatically after encrypted
model verification. Devices that hide it still require an independently obtained
token; no Xiaomi Cloud lookup is performed. See
[verification and remaining limits](smartthings/LOCAL_DISCOVERY.md).

### First-time login (no manual token entry)

Use the [one-time Xiaomi QR login helper](xiaomi-miio/onboarding/README.md) to
retrieve supported devices and transfer credentials to the hub. The helper exits
after enrollment. Subsequent control remains local and does not require the Mac
or Xiaomi Cloud. Manual setup remains available below.

### Installation

For an existing published build, enroll using the invite link:

<https://bestow-regional.api.smartthings.com/invite/KPMekJRvL0lQ>

Then select **Add device → Scan nearby**. Each scan creates one **Xiaomi 기기
설정** record. Open its settings and select the model, then enter:

- A reserved/static LAN IPv4 address.
- Its 32-character hexadecimal Xiaomi token.

Once valid settings are saved, the same record changes to the selected device
profile and refreshes immediately. SmartThings commands update the UI
optimistically, verify related LAN properties after 0.5 seconds, and retry once
at about 2 seconds before rolling back a mismatch. External button/Mi Home
changes are polled every 20 seconds for core properties and every 5 minutes for
secondary properties. Scan again when adding another Xiaomi device; unused
model placeholders are never created.

The default profile shows only frequent controls. Enable **고급 기능 표시** in
device settings to add maintenance, indicator, buzzer, lock, sensor, and
diagnostic controls without recreating the device. IP and token settings use
the same preference names in both profiles and remain attached to the device.

Fault events are emitted only when the confirmed fault changes. Both air
purifier profiles expose fault status and a filter replacement condition:
10% or less activates it, and a confirmed reading above 15% clears it.
The optional [Docker notification service](notification-service/README.md) runs on
the Mac server and sends per-device SmartThings push messages directly, with the
physical device's name and link. It polls confirmed fault/filter attributes,
refreshes OAuth credentials, persists duplicate suppression, and retries failures.
The driver keeps **Xiaomi 알림** as a history and test-request endpoint; it no longer
emits button events that trigger the old notification routine.
See [notification conditions and verification](smartthings/ALERTS.md).

Device-specific [UI configurations](smartthings/device-configs/) keep measured
humidity read-only, restrict enums to the actual hardware, show the fan's remaining
timer as one continuous control, and move filter reset to the advanced view.
The purifier's automation-only filter warning remains available to the notifier
without adding a duplicate status card.

The mobile layout puts fan speed first and uses a compact oscillation dropdown.
The dehumidifier's basic view shows current humidity without the large history
chart, so target humidity and mode fit on the first screen. Standard sensor
history and automation capabilities remain available. See the
[UI configuration guide](smartthings/UI.md) and
[ADB verification report](smartthings/UI_AUDIT.md) for deployment and device-tested results.

### Xiaomi code flow

```text
SmartThings capability command
  → src/command_handlers.lua
  → src/devices/<model>.lua (MiOT siid/piid mapping)
  → src/miio/client.lua
  → encrypted UDP/54321 packet
```

Each refresh performs one MiIO handshake and reads properties in small chunks.
Individual MiOT result codes and packet checksums are validated before state is
applied. Commands emit an optimistic UI event, execute asynchronously, and then
refresh the real device state.
Once an appliance DID is known, control sessions keep that identity even if an
address or token changes. Replies must match the requested MiOT attributes;
readbacks from a replaced connection cannot update the current device UI.

## Repository layout

```text
xiaomi-miio/
  config.yml
  profiles/
  src/
    init.lua
    discovery.lua
    command_handlers.lua
    models.lua
    devices/
    miio/
smartthings/
  capabilities/             # custom capability schemas and presentations
tests/
  run.lua
  test_notifier.py
notification-service/       # Docker Compose direct push service and installer
```

## Development

Prerequisites:

- SmartThings Edge-capable hub.
- Authenticated [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli).
- Lua 5.3+ with `luasocket` and `dkjson` for host-side tests.

Run the regression tests:

```bash
lua tests/run.lua .
lua tests/test_xiaomi_discovery.lua .
lua tests/test_xiaomi_enrollment.lua .
lua tests/test_xiaomi_ui.lua .
python3 -m unittest discover -s tests -p 'test_notifier*.py'
```

After installing the [Xiaomi onboarding dependencies](xiaomi-miio/onboarding/README.md),
run all Python regression tests with the same environment:

```sh
xiaomi-miio/onboarding/.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

Regression tests use scripted transports and loopback servers. They cover device
identity conflicts, pending enrollment and expiry, malformed and partial replies,
command queue recovery, storage failures, OAuth rotation, and per-device health.
They do not replace appliance, hub SDK, or mobile app verification.

Reproduce the host CPU benchmarks without device or network traffic:

```sh
lua scripts/benchmark_miio.lua . 1000
python3 scripts/benchmark_notifier_tls.py --iterations 100 --repeats 5
python3 scripts/benchmark_tuya.py
```

The MiIO benchmark accepts another checkout as its first argument for comparison.
The Tuya benchmark accepts `--source-root` and uses the public catalog and mocked
hub/SDK clients. Browsing all 72 profiles retained 16.43 MB before the cache limit
and 0.43 MB afterward; ten unchanged daily polls emitted 120 events before and
none after the initial snapshot, with all ten health reads retained.
On the development host, parsing 1,000 fixed 144-byte encrypted replies took
2.196 s before the AES change and 0.313 s afterward. TLS trust configuration
initialization took 2.805 ms per connection with the default context and 0.0026 ms
with the notifier's reused verified context. These measure local processing,
not network, TLS handshake, hub, or appliance response times.

Repeated Xiaomi control values use the SDK's latest state to avoid duplicate
publications. Sensor/history samples and fault, alert, and maintenance policies
retain their existing cadence. Local UI checks also verify visible Tuya connection
feedback and Korean labels for every catalog temperature range; see the dated
[UI audit](smartthings/UI_AUDIT.md) and [Tuya results](tuya-local/TEST_RESULTS.md).

Build packages without uploading:

```bash
smartthings edge:drivers:package --build-only /tmp/xiaomi-miio.zip xiaomi-miio
```

Publish and install with the normal SmartThings Edge channel workflow:

```bash
smartthings edge:drivers:package xiaomi-miio
smartthings edge:channels:assign <channel-id> <driver-id>
smartthings edge:drivers:install <driver-id>
```

For Xiaomi development, the protocol client can also be exercised directly:

```bash
cd xiaomi-miio/src
lua -e '
package.path = "./?.lua;./?/?.lua;" .. package.path
local Client = require "miio.client"
local client, err = Client.new{
  ip = "192.168.1.4",
  token = "<32-hex-token>",
}
assert(client, err)
local info, request_err = client:miio_info()
print(info and info.model or request_err)
'
```

## Security notes

- Keep Xiaomi tokens out of source control and logs.
- Xiaomi tokens use password-style SmartThings preferences.
- Reserve Xiaomi device IPs in DHCP so control does not move to another host.
- Follow [publication privacy checks](PRIVACY.md) before committing configuration or deployment changes.

## References

- [SmartThings Edge driver documentation](https://developer.smartthings.com/docs/devices/hub-connected/edge-drivers)
- [python-miio](https://github.com/rytilahti/python-miio)
- [MiOT specification API](https://miot-spec.org/miot-spec-v2/instances?status=all)

## Tuya IR 에어컨

[Tuya 로컬 제어](tuya-local/README.md): 인증된 자동 연결, 스마트싱스 기종 선택·온도·모드·풍량 시험 UI, LAN 브리지. 실행 서비스는 지정한 IR 허브로만 발신 연결을 허용합니다.

삼성·LG·캐리어·위니아의 Tuya 71개 코드셋·7,723개 키 전체의 로컬 송신 원문을 확보·검증했습니다. 기존 Carrier를 합쳐 72개 코드셋을 포함하고 다른 브랜드는 제외합니다. 브리지·드라이버 배포와 실제 휴대폰 화면 검증을 완료했습니다. [수집 절차와 배포 조건](tuya-local/commissioning/README.md)을 참고하세요.

Tuya 검증:

```sh
python3 -m unittest discover -s tests -p 'test_tuya*.py'
lua tests/test_tuya_client.lua
lua tests/test_tuya_ux.lua
python3 scripts/check_public_data.py
```

### Manual-based operating behavior

See the [three-model manual audit](smartthings/MANUAL_AUDIT.md) for source manuals,
firmware observations, operating limits and deployment checks. Dehumidifier
humidity is adjustable only in smart/sleep modes (40–70%). Mode changes refresh
the device-reported target. Its standby timer supports 12 hours; advanced controls
include post-shutdown drying and remaining drying time. The fan timer follows the
manual’s 8-hour limit. Purifier manual level 0 is a valid setting, and filter reset
requires verified standby. Firmware retains control of compressor protection and
automatic drying/defrost sequences.
