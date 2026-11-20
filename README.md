# edge_iot — SmartThings Edge 로컬 제어

Xiaomi MiIO/MiOT 기기와 Tuya IR 에어컨을 SmartThings에서 제어합니다.
Xiaomi 제어는 허브에서 직접 실행하고, Tuya IR과 기기별 푸시는 Docker 컨테이너로 실행합니다.

## 구성

| 구성 요소 | 실행 위치 | 역할 |
|---|---|---|
| `xiaomi-miio/src/` | SmartThings 허브 | 암호화된 UDP/54321로 Xiaomi 검색·인증·제어 |
| `xiaomi-miio/onboarding/` | 최초 등록 시 1회 실행 | Xiaomi QR 로그인과 일회용 암호화 자격증명 전달 |
| `tuya-local/src/` | SmartThings 허브 | 기종 선택·시험·저장 UI와 LAN 브리지 명령 |
| `tuya-local/bridge/` | Docker | 내장 IR 코드표를 사용해 지정한 Tuya 허브로 송신 |
| `notification-service/` | Docker | 확인된 Xiaomi 경고를 조회해 SmartThings 직접 푸시 |
| `smartthings/` | 개발·배포 자료 | capability, presentation, 번역, 화면 구성 |
| `tests/`, `scripts/` | 개발 환경 | 단위 테스트 및 공개 데이터 검사 |

```text
SmartThings → Xiaomi Edge → MiIO UDP → Xiaomi 기기
SmartThings → Tuya Edge → 인증된 LAN HTTP → 브리지(Docker) → Tuya 허브 → IR
Xiaomi 확정 상태 → SmartThings → 알림 서비스(Docker) → 기기별 푸시
```

## Xiaomi 설치와 동작

| 기기 | 모델 | 주요 기능 |
|---|---|---|
| Mi Smart Standing Fan 2 | `zhimi.fan.za5` | 전원, 풍량, 바람 모드, 좌우 회전, 8시간 꺼짐 예약 |
| Mi Air Purifier 4 Compact | `zhimi.airp.cpa4` | 전원, 모드, PM2.5, 수동 풍량(0–14), 필터 수명 |
| Xiaomi Smart Dehumidifier 13L | `xiaomi.derh.13l` | 전원, 모드, 목표 습도(40–70%), 12시간 꺼짐 예약, 건조·고장 상태 |

1. [드라이버 초대 링크](https://bestow-regional.api.smartthings.com/invite/KPMekJRvL0lQ)에서 드라이버를 설치하고 **기기 추가 → 주변 검색**으로 `Xiaomi 기기 설정`을 만듭니다.
2. [QR 로그인 도우미](xiaomi-miio/onboarding/README.md)로 토큰을 허브에 전달하거나, 설정 기기에서 모델·IPv4 주소·32자리 토큰을 직접 입력합니다.
3. 허브는 5분마다 및 새로고침 시 LAN을 검색해 암호화된 모델·DID를 확인하고 주소를 갱신합니다.
4. 기기 설정의 **고급 기능 표시**로 표시등·조작음·버튼 잠금·필터 초기화 기능을 활성화합니다. 상세 내용은 [화면 구성](smartthings/UI.md), [기기별 동작 규칙](smartthings/MANUAL_AUDIT.md), [로컬 검색](smartthings/LOCAL_DISCOVERY.md)을 참고하세요.

## Tuya IR 에어컨

[Tuya 브리지 안내](tuya-local/README.md)에 따라 Docker 컨테이너를 실행하고 `connect_smartthings.py`로 허브와 연결합니다. 삼성·LG·캐리어·위니아 72개 코드셋을 내장하고 있으며, 앱에서 후보 기종을 시험한 뒤 저장합니다.

## 기기별 알림

[알림 서비스 안내](notification-service/README.md)에 따라 Docker 컨테이너를 실행합니다. Xiaomi 제습기·공기청정기의 고장·필터 속성을 15초마다 조회해 기기 이름과 기기 링크로 푸시합니다. 새 경고는 즉시 알리고 지속 시 24시간마다 재알림합니다. 상세 조건은 [알림 조건](smartthings/ALERTS.md)과 [직접 푸시 API](smartthings/NOTIFICATIONS_API.md)를 참고하세요.

## 배포 설정과 검증

공개 배포 식별자(namespace, package key, 지원 URL)는 [`integration.json`](integration.json)에서 단일 관리합니다.

```sh
python3 scripts/configure_integration.py
python3 scripts/configure_integration.py --check
```

저장소 루트에서 테스트 실행:

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

드라이버 패키징 및 배포:

```sh
smartthings edge:drivers:package xiaomi-miio --channel CHANNEL_ID --hub HUB_ID
smartthings edge:drivers:package tuya-local --channel CHANNEL_ID --hub HUB_ID
```

Tuya 브리지와 알림 서비스는 각각의 디렉터리(`tuya-local/bridge`, `notification-service`)에서 `docker compose up -d --build`로 배포합니다. 커밋 전 [공개 데이터 검사](PRIVACY.md)를 실행합니다.
