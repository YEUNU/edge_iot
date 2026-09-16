# Xiaomi local discovery verification — 2026-09-16

The driver discovers miIO devices over UDP/54321, broadcasts twice and also probes
known addresses. It repeats discovery at startup and every five minutes. Nearby
scan and Refresh on the existing setup device also invoke discovery.

A hello response is not authenticated. A nonzero/non-FF checksum is treated only
as a candidate token. An encrypted miIO.info response naming a supported model
must succeed before credentials are persisted or a device is created. Existing
preferences are reused for previously configured devices. Discovery never calls
Xiaomi Cloud. No host bridge is used for control or discovery.

## Confirmed on physical devices

- Air purifier, fan and dehumidifier:
  direct hello replies received; all three omit a usable token.
- The actual SmartThings Station authenticated all three using existing tokens
  after installing the discovery driver (hub logs at 21:16 KST).
- Fan command sent through SmartThings: speed 35 → 36. Independent encrypted LAN
  read returned speed-percent=36, power=true. Independent read after restoration confirmed 35.
- Existing physical device IDs were retained. The setup placeholder is not a
  connected physical device.
- 42 existing Lua regression tests pass. Additional tests cover malformed hello,
  token sentinels, authenticated creation, failed authentication, pending creation
  deduplication, credential restoration, IP migration and missing tokens.

- Final installed version confirmed via hub API:
  `2026-09-16T12:21:40.659970537`.
- Air purifier: SmartThings auto → sleep, independent LAN read mode=1;
  restored auto and independently read mode=0.
- Dehumidifier: SmartThings target humidity 55 → 60; independent LAN read
  target=60; restored 55, independent LAN read and hub poll confirm target=55.

## Actual hub integration with a simulated miIO device

The explicitly started `tests/miio_hub_emulator.lua` fixture bound UDP/54321 on
the test host's LAN address and accepted traffic only from the SmartThings Station. Its public
fixture key and DID 2130706001 are not household credentials.

- 21:20 KST: exposing a candidate key allowed the actual hub to authenticate,
  create a temporary test device, and poll it.
- SmartThings preferences confirmed no manually configured token. A SmartThings
  speed command produced encrypted writes power=true and speed=42 at the fixture.
- The fixture was restarted in hidden-token mode, then the driver code was
  updated. The hub logged the device's new init at 21:21:55. A subsequent command
  reached the fixture (speed=43), and SmartThings status reported 43. This verifies
  hub credential persistence across driver restart without token rediscovery.
- 21:22:24: the test record was deleted. Another local scan at 21:22:29 found the
  hidden-token fixture but correctly declined enrollment. API enumeration
  confirmed zero remaining fixture records and the five original Xiaomi records.
- Existing real appliances authenticated again after the final driver update.

This is real SmartThings enrollment/control of a protocol simulator, not evidence
that a new physical Xiaomi model exposes its key. Both test processes were stopped
when verification finished. No runtime bridge is required by the deployed driver.

## Not yet established

- Physical enrollment of a NEW device exposing its token. Available appliances
  do not expose one; mock authentication tests are not physical enrollment proof.
- Actual DHCP address change recovery; tested with simulated discovery only.
- Comprehensive command matrix on all three appliances after the final package.
- Physical motor/sensor behavior beyond the command checks recorded above.
  Phone UI rendering was subsequently checked with ADB; see [UI audit](UI_AUDIT.md).
- Full internet disconnection test. Source inspection establishes no Xiaomi
  Cloud requests by this driver, not lack of cloud traffic from device firmware.

A short-lived SmartThings-to-bridge pairing ticket cannot obtain an unknown miIO
key. It only transports credentials already known by that bridge. New devices
that hide their token cannot be enrolled without another authorized key source.
The requested universal cloud-free, zero-token-input enrollment is not achieved.

## Physical fan with deletion-equivalent empty discovery state

User-requested test: assume the fan has been removed and is being added afresh.
`tests/miio_fresh_enrollment.lua` ran the production discovery code with empty
`get_devices()`, an empty datastore, and no preferences/tokens. It consumed fresh
UDP responses from the actual fan (household identifiers omitted). An additional
unicast probe separated token availability from broadcast reachability.

Observed results:

```
broadcast_found=true
physical_reply did=<redacted> token_candidate=false
fresh_authenticated_registration_requests=0
fresh_credentials_saved=false
```

The fan is discoverable, but does not disclose its local key, so fresh automatic
registration cannot authenticate. This is a deletion-equivalent discovery-state
test on the host using physical responses, NOT actual deletion/recreation of the
SmartThings record and NOT a factory reset. The existing fan record was retained;
SmartThings health was ONLINE and reported speed remained 35. It did not consume
saved household credentials to make the fresh-registration test pass.

## Scope update: one-time Xiaomi login authorized

The user subsequently authorized Xiaomi account login for initial onboarding.
The deployed driver still controls appliances exclusively over LAN. A separate,
short-lived `xiaomi-miio/onboarding/onboard.py` QR helper retrieves credentials
and transfers them to the hub using an expiring encrypted LAN exchange.

Deployment: `2026-09-16T12:34:49.37600868`. The actual setup device exposes
`earthpanel38939.xiaomiLocalLink`, and its capability presentation was created.
Four Python integration tests passed, including real Python HTTP ↔ Lua packet
exchange, corrupted packet rejection, expiry and single-use behavior. Existing
42 Lua regressions and discovery/imported-token preference tests passed.

At this checkpoint QR login approval is pending. Real Xiaomi account token
retrieval and real-hub import through this new helper are not yet verified.
The prior simulator and local discovery results do not substitute for that test.
The `Xiaomi 기기 설정` record remains necessary as the enrollment command endpoint.

### Actual hub import transport verified; account login still pending

At 21:40 KST the new onboarding transport was exercised against the actual hub
using the existing fan's credential read into memory from SmartThings preferences.
No credential file/export was created. The helper returned:

```
{"failed": 0, "requested": 0, "updated": 1}
```

The setup device's actual capability status was `연결 확인 1 · 등록 요청 0 · 실패 0`.
This proves encrypted helper-to-hub transfer and actual fan authentication through
the new handler. It does NOT prove Xiaomi Cloud login/token retrieval, since the
credential source for this test was existing preferences. The transfer server
exited after its acknowledgement. The QR login helper separately expired without
user approval and removed its QR file. No login session remains running.

### Xiaomi QR login and three physical imports completed

After the user approved the renewed QR, the actual helper reported
`LOGIN_CONFIRMED`, retrieved all three supported household models from Xiaomi,
and completed the encrypted LAN transfer to the real hub. Final acknowledgement:

```
{"failed": 0, "requested": 0, "updated": 3}
```

The actual SmartThings setup status at `2026-09-16T12:42:47.343Z` was
`연결 확인 3 · 등록 요청 0 · 실패 0`. Existing device IDs were preserved (no duplicate
physical device records were requested). The helper exited successfully, the QR
file was removed, and no onboarding process remained running.

After helper shutdown, SmartThings fan commands were independently verified by
polling the appliance's encrypted LAN property until it matched: speed 36, then
restoration to 35. Immediate reads can precede asynchronous command execution;
only the confirmed settled readings are counted as command verification.

Completion scope: local discovery/candidate authentication, one-time account
login import, actual hub credential delivery and authentication of three physical
devices, retained local control after helper shutdown. The earlier physical
appliance checks and actual-hub simulated-device creation cover their stated
cases. They do not assert compatibility with untested models or every command.
A new physical appliance with no prior record was not available for fresh-cloud
creation testing. Actual DHCP reassignment was not performed; two subsequent
host tests with a deliberately stale stored fan IP failed because the fan did
not answer broadcasts on those runs. Keep DHCP reservations for dependable
addressing; local discovery cannot guarantee a reply from a sleeping/isolated
appliance. Universal token-free LAN onboarding remains unsupported on the tested
models; initial Xiaomi login is the user-authorized solution.
