# edge_iot — SmartThings Edge driver

SmartThings Edge drivers for Xiaomi MiIO/MiOT devices and Tuya IR air conditioners, with local control paths.

## Xiaomi MiIO LAN

The primary driver controls three Xiaomi models directly over UDP/54321. It
does not use Xiaomi Cloud. The per-device token is stored in the SmartThings
device preferences and is used to derive the MiIO AES-128-CBC key and IV.

| Device | MiOT model | Main capabilities |
|---|---|---|
| Mi Smart Standing Fan 2 | `zhimi.fan.za5` | Power, speed, oscillation, wind mode, off timer |
| Mi Air Purifier 4 Compact | `zhimi.airp.cpa4` | Power, mode, PM2.5, favorite level, filter life |
| Xiaomi Smart Dehumidifier 13L | `xiaomi.derh.13l` | Power, mode, current/target humidity, fault status |

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
python3 -m unittest discover -s tests -p 'test_notifier*.py'
```

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

[Tuya 로컬 제어](tuya-local/README.md): 313개 사전 코드셋, 인증된 자동 연결, 스마트싱스 기종 선택·온도·모드·풍량 시험 UI, LAN 브리지. 모드와 풍량은 드롭다운으로 고릅니다. 실행 서비스는 지정한 IR 허브로만 발신 연결을 허용합니다. 실제 호환 여부는 기종별 확인이 필요합니다.

Tuya 허브용 목록 1,325개와 API 코드 레코드 163,693개는 일회성 수집을 완료했습니다. 이 추가 데이터의 로컬 송신 형식 변환은 미완료이며, 전체 Tuya 기종을 로컬에서 지원한다는 의미는 아닙니다. [수집 범위와 남은 작업](tuya-local/commissioning/README.md)을 참고하세요.

Tuya 검증:

```sh
python3 -m unittest discover -s tests -p 'test_tuya*.py'
lua tests/test_tuya_client.lua
lua tests/test_tuya_ux.lua
python3 scripts/check_public_data.py
```
