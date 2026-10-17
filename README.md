# edge_iot — SmartThings Edge 로컬 제어

Xiaomi MiIO/MiOT 기기와 Tuya IR 에어컨을 SmartThings에서 제어합니다.
Xiaomi 제어는 허브에서 직접 실행하고, Tuya IR과 기기별 푸시는 Mac의 Docker 서비스를 사용합니다.

## 구성

| 구성 요소 | 실행 위치 | 역할 |
|---|---|---|
| `xiaomi-miio/src/` | SmartThings 허브 | 암호화된 UDP/54321로 Xiaomi 검색·인증·제어 |
| `xiaomi-miio/onboarding/` | 최초 등록 시 Mac | Xiaomi QR 로그인과 일회용 암호화 자격증명 전달 |
| `tuya-local/src/` | SmartThings 허브 | 기종 선택·시험·저장 UI와 LAN 브리지 명령 |
| `tuya-local/bridge/` | Mac/서버 Docker | 내장 IR 코드표를 사용해 지정한 Tuya 허브로 송신 |
| `notification-service/` | Mac/서버 Docker | 확인된 Xiaomi 경고를 조회해 SmartThings 직접 푸시 |
| `smartthings/` | 개발·배포 자료 | capability, presentation, 번역, 화면 구성 |
| `tests/`, `scripts/` | 개발 환경 | 회귀 검사, 공개 데이터 검사, 로컬 벤치마크 |

```text
SmartThings → Xiaomi Edge → MiIO UDP → Xiaomi 기기
SmartThings → Tuya Edge → 인증된 LAN HTTP → 브리지 → Tuya 허브 → IR
Xiaomi 확정 상태 → SmartThings → 알림 서비스 → 기기별 푸시
```

평소 제어 경로는 Xiaomi·Tuya 클라우드 API를 호출하지 않습니다. 최초 Xiaomi 로그인과
Tuya 코드 수집은 별도 도구이며, SmartThings 앱·계정·푸시는 인터넷을 사용합니다.

## Xiaomi 설치와 동작

| 기기 | 모델 | 주요 기능 |
|---|---|---|
| Mi Smart Standing Fan 2 | `zhimi.fan.za5` | 전원, 풍량, 바람 모드, 좌우 회전, 8시간 꺼짐 예약 |
| Mi Air Purifier 4 Compact | `zhimi.airp.cpa4` | 전원, 모드, PM2.5, 수동 풍량, 필터 수명 |
| Xiaomi Smart Dehumidifier 13L | `xiaomi.derh.13l` | 전원, 모드, 습도, 12시간 꺼짐 예약, 건조·고장 상태 |

[드라이버 초대 링크](https://bestow-regional.api.smartthings.com/invite/KPMekJRvL0lQ)에서
등록한 뒤 **기기 추가 → 주변 검색**으로 `Xiaomi 기기 설정`을 만듭니다.
[QR 로그인 도우미](xiaomi-miio/onboarding/README.md)를 실행하면 토큰을 수동으로
복사하지 않고 허브에 전달할 수 있습니다. 도우미는 등록 후 종료합니다.
수동 등록은 설정 기기에서 모델, LAN IPv4 주소, 32자리 16진수 토큰을 입력합니다.
설정을 저장하면 같은 기기 항목이 해당 모델의 화면으로 바뀝니다.

허브는 시작 시, 5분마다, 주변 검색 및 설정 기기의 새로고침 때 LAN을 검색합니다.
발견 응답만으로 기기를 신뢰하지 않고 암호화된 모델·DID 응답을 확인합니다.
토큰을 공개하지 않는 기기는 기존 인증값이나 최초 로그인 도우미가 필요합니다.
로그인 등록과 LAN 검색은 같은 비동기 등록·중복 방지 경로를 사용합니다.
주소를 안정적으로 유지하려면 DHCP 예약을 권장합니다.

명령은 기기별로 순서대로 실행합니다. UI를 먼저 갱신한 뒤 0.5초 후 실제 값을
확인하고, 약 2초 시점에 한 번 더 확인해 불일치하면 되돌립니다. 기본 속성은
20초, 보조 속성은 5분마다 조회합니다. 이전 연결이나 명령 전 폴링의 오래된 응답이
최신 UI를 덮어쓰지 않도록 검사합니다.

기기 설정의 **고급 기능 표시**로 표시등·조작음·버튼 잠금·관리 기능을 추가합니다.
제습기 목표 습도는 스마트·수면 모드에서 40–70%, 공기청정기 수동 풍량은 0–14입니다.
필터 초기화는 실제 대기 상태를 확인한 뒤 실행합니다. 압축기 보호·제상·자동 건조는
펌웨어가 담당합니다. [화면 구성](smartthings/UI.md)과
[기기별 동작 근거](smartthings/MANUAL_AUDIT.md)를 참고하세요.

## Tuya IR 에어컨

[Tuya 설치와 사용법](tuya-local/README.md)에 따라 브리지를 실행하고 자동 연결 도우미로
허브와 연결합니다. 삼성·LG·캐리어·위니아의 71개 코드셋·7,723개 원문 키와 기존
Carrier 코드셋을 합쳐 72개를 제공합니다. 기종별 실제 호환성은 에어컨에서 확인해야 합니다.

기종을 선택하는 동작은 IR을 보내지 않습니다. 후보를 선택한 뒤 시험 전원·온도·모드·풍량을
조작하고 반응을 확인해 저장합니다. 버튼형 기종은 원문 버튼 선택과 송신을 분리합니다.
IR은 단방향이므로 앱 상태는 마지막 송신 기준입니다. 재시작 후 전원 상태는 미확인으로
표시하며, 기종별 마지막 온도·모드·풍량은 복원합니다.

## 기기별 알림

[알림 서비스](notification-service/README.md)는 선택한 Xiaomi 제습기·공기청정기의
확정된 고장·필터 속성을 15초마다 조회합니다. 실제 기기 이름과 해당 기기 링크로
푸시하며 별도 SmartThings 루틴은 필요 없습니다. `Xiaomi 알림`은 기록·테스트 요청용입니다.

새 경고는 즉시 알리고, 계속 확인되는 경고는 마지막 전송 성공부터 24시간마다 다시 알립니다.
반복 조회·재시작은 중복 알림을 만들지 않습니다. 정상 복구 후 재발하면 즉시 알리며,
제습기는 필터 청소 경고만 5분간 연속 확인해도 다음 만수 알림을 다시 허용합니다.
[알림 조건](smartthings/ALERTS.md)과
[API·인증 계약](smartthings/NOTIFICATIONS_API.md)을 참고하세요.

## 배포 설정

공개 배포 식별자(namespace, 두 드라이버의 package key, 지원 URL)는
[`integration.json`](integration.json)에서 관리합니다. 변경 후 아래 명령으로
Lua·Python 설정과 SmartThings 프로필·화면 참조를 함께 갱신합니다.

```sh
python3 scripts/configure_integration.py
python3 scripts/configure_integration.py --check
```

다른 계정으로 배포할 때는 `python3 scripts/configure_integration.py --namespace YOUR_NAMESPACE`를
실행합니다. namespace가 바뀐 프로필의 이전 `vid`는 제거되므로 Xiaomi·Tuya UI를 해당
계정에 등록한 뒤 드라이버를 패키징해야 합니다. 기존 설치를 갱신할 때는 namespace와
package key를 유지합니다. IP·허브/기기 ID·토큰은 실행 시 입력하거나 비공개 설정에서 읽습니다.

## 개발과 검증

SmartThings CLI, Lua 5.3 이상의 `luasocket`·`dkjson`, Python 환경이 필요합니다.
전체 Python 검사는 [로그인 도우미 의존성](xiaomi-miio/onboarding/README.md)을 설치한
환경에서 실행합니다. 저장소 루트에서:

```sh
xiaomi-miio/onboarding/.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
lua tests/run.lua .
lua tests/test_xiaomi_discovery.lua .
lua tests/test_xiaomi_enrollment.lua .
lua tests/test_xiaomi_ui.lua .
lua tests/test_tuya_client.lua
lua tests/test_tuya_ux.lua
python3 tuya-local/commissioning/verify_korean_release.py tuya-local/bridge/catalog --require-existing
python3 scripts/check_public_data.py
```

테스트는 모의 전송·SDK·루프백 서버를 사용합니다. 실제 기기 제어·휴대폰 표시·푸시 수신과
구분하며 [검증 절차](smartthings/VERIFICATION.md), [Tuya 검증 범위](tuya-local/TEST_RESULTS.md)에
배포 후 확인 항목을 정리합니다.

네트워크 없이 CPU·캐시·이벤트 비용을 비교하려면:

```sh
lua scripts/benchmark_miio.lua . 1000
python3 scripts/benchmark_notifier_tls.py --iterations 100 --repeats 5
python3 scripts/benchmark_tuya.py
```

이 측정은 LAN 지연·기기 응답·휴대폰 수신 시간을 뜻하지 않습니다.

## 배포

먼저 `python3 scripts/configure_integration.py --check`로 배포 설정을 확인한 뒤 두 패키지를 로컬에서 빌드합니다.

```sh
smartthings edge:drivers:package --build-only /tmp/xiaomi-miio.zip xiaomi-miio
smartthings edge:drivers:package --build-only /tmp/tuya-local.zip tuya-local
```

화면 정의를 바꿨다면 [Xiaomi UI 배포](smartthings/UI.md) 또는
[Tuya UI 배포](tuya-local/README.md#코드와-ui-재생성)를 먼저 실행합니다.
로그인된 CLI에서 기존 채널·허브로 배포합니다.

```sh
smartthings edge:drivers:package xiaomi-miio --channel CHANNEL_ID --hub HUB_ID
smartthings edge:drivers:package tuya-local --channel CHANNEL_ID --hub HUB_ID
```

Tuya 브리지는 `tuya-local/bridge`에서 `docker compose up -d --build`로 갱신합니다.
알림 서비스 갱신은 해당 [관리 안내](notification-service/README.md)를 따릅니다.
허브 설치 버전, 컨테이너 코드, 기기 연결 상태를 확인해야 배포 완료입니다.
인증·설정·상태 파일과 개인 식별자는 저장소에 넣지 않습니다.
커밋 전 [공개 데이터 검사](PRIVACY.md)를 실행합니다.
