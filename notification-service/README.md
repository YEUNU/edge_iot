# Xiaomi 기기별 직접 알림 — Docker Compose

Mac 서버의 Docker에서 실행하며 SmartThings 루틴을 사용하지 않습니다. 알림 제목은
실제 기기 이름이고, 누르면 해당 기기 화면이 열립니다. 감시 대상은 사용자가 선택한
샤오미 제습기·공기청정기입니다. 다른 제조사 기기는 포함하지 않습니다.

## 관리

현재 배포 디렉터리는 `~/Library/Application Support/Xiaomi Notifications`입니다.
Docker Desktop에서 `xiaomi-notifications` 프로젝트/컨테이너로 관리할 수 있습니다.

```sh
cd "$HOME/Library/Application Support/Xiaomi Notifications"
docker compose ps
docker compose logs --tail 50 -f
docker compose restart
docker compose stop
docker compose up -d
```

`restart: unless-stopped`로 Docker 재시작이나 프로세스 비정상 종료 후 다시 실행됩니다.
사용자가 `stop`한 경우에는 `up -d`로 켭니다. Mac과 Docker가 실행 중이어야 하며,
종료·로그아웃으로 Docker가 멈추거나 Mac이 잠자기에 들어가면 알림도 멈춥니다.
컨테이너 재생성은 인증·상태를 지우지 않습니다. `auth.json`, `config.json`,
`state.json`은 위 디렉터리에 보관하며 `/data`로 마운트합니다.

Docker healthcheck는 각 감시 기기와 테스트 endpoint의 조회 성공을 따로 확인합니다.
마지막 정상 조회가 120초 이상 지나면 `unhealthy`가 됩니다. 시작 후 아직 조회하지
못한 기기에는 서비스 시작 시각부터 120초 유예를 적용합니다. 누락·알 수 없는
속성은 기존 경보를 유지하지만 정상 조회로 세지 않습니다. 오프라인 응답은 조회
성공으로 세며 경보를 해제하지 않습니다. 대기 중인 전송 실패나 상태 저장 실패도
health에 반영합니다. `unhealthy`는
로그를 확인할 신호이며, Docker가 health 상태만으로 컨테이너를 재시작하는 것은
아닙니다. 서비스 자체는 네트워크/API 오류에 계속 재시도합니다. 로그는 파일당
5MB, 최대 3개로 순환합니다. 외부에 여는 포트는 없습니다.

## 처음 설치하거나 기기 구성을 바꿀 때

Mac에 Python 3.9 이상, SmartThings CLI, Docker Compose가 필요합니다. 별도 Python
패키지는 필요 없습니다. 전용 프로필로 한 번 로그인한 뒤 설치합니다.

```sh
smartthings locations -p xiaomi-alerts
python3 notification-service/install.py \
  --location LOCATION_ID \
  --device DEHUMIDIFIER_ID --device PURIFIER_ID \
  --test-device XIAOMI_ALERTS_ID
```

실행 중인 서비스의 구성을 바꿀 때는 먼저 `docker compose stop`을 실행합니다.
`--prepare-only`를 추가하면 설정과 Compose 구성을 검증하고 컨테이너는 시작하지
않습니다. `--data-dir PATH`로 배포 디렉터리를 바꿀 수 있으며 따옴표·역슬래시·
줄바꿈·`$`가 포함된 경로도 `.env` 문법에 맞게 인코딩합니다. 설치 프로그램은 실제 모델과
장소를 확인하고 독립 CLI 프로필의 인증 소유권을 서비스로 옮깁니다. 기본 CLI의
refresh token을 복사하지 않습니다. 서비스는 공식 CLI와 같은 OAuth 갱신 경로를
사용하며 새 refresh token을 원자적으로 저장합니다. 이미 준비된 인증은 재설치 시
유지합니다. 토큰 파일은 권한 0600이며 Git과 이미지에 포함하지 않습니다.
인증 이관 도중 저장이 실패하면 같은 설치 명령을 다시 실행해 이어서 처리합니다.
이관 후 새로 로그인한 CLI 세션은 삭제하지 않습니다.
`.dockerignore`는 실행 코드와 Dockerfile만 빌드 컨텍스트에 허용합니다.

namespace는 저장소의 [배포 설정](../README.md#배포-설정)에서 생성하며, 설치 시
`integration_settings.py`가 실행 코드와 함께 복사됩니다. 코드를 갱신할 때는 서비스를 멈춘 뒤 위 설치 명령을 다시 실행합니다. 설치된
배포 디렉터리의 코드 자체를 수정한 경우에는 `docker compose up -d --build`로
다시 빌드할 수 있습니다.

## 테스트

SmartThings **Xiaomi 알림 → 테스트 알림 보내기**를 누르면 Docker 서비스가 테스트
푸시를 보냅니다. 이 명령은 실제 기기의 고장·필터 상태를 바꾸지 않습니다. 설치 전
오래된 테스트 요청은 재전송하지 않습니다. 호환용 `button` capability는 유지하지만
`pushed` 이벤트를 발행하지 않으므로 버튼을 조건으로 한 루틴을 실행하지 않습니다.

관리용 명령은 동시에 인증을 갱신하지 않도록 서비스를 멈추고 실행합니다.

```sh
cd "$HOME/Library/Application Support/Xiaomi Notifications"
docker compose stop
docker compose run --rm --no-deps notifier --refresh-auth
docker compose run --rm --no-deps notifier --test DEHUMIDIFIER_ID
docker compose up -d
```

저장소 테스트:

```sh
python3 -m unittest discover -s tests -p 'test_notifier*.py'
lua tests/run.lua .
```

HTTPS 요청은 검증된 TLS 신뢰 설정을 재사용합니다. 요청별 handler와 인증 헤더는
따로 만들며, 인증서·호스트 이름 검증과 redirect 차단을 유지합니다.
`python3 scripts/benchmark_notifier_tls.py`는 저장소 루트에서 네트워크 연결 없이
TLS 설정 초기화 비용만 비교합니다. 연결·handshake·알림 도착 시간은 측정하지 않습니다.

## 알림 조건과 동작

모델별 capability·속성·경고 문구는 [notifier.py](notifier.py)의 `CONDITIONS`에서
정의합니다. 설치 시 지원 모델 확인, 상태 조회, 정상 조회에 필요한 속성 개수,
중복 억제에 사용하는 경고 목록이 모두 이 정의를 사용합니다.

- 제습기: 물통 가득 참, 센서·내부 통신·팬 모터 오류, 필터 청소, 과부하,
  냉매 부족. 정상과 제상은 푸시 대상에서 제외합니다.
- 공기청정기: 모터·센서 오류, 필터 교체. 필터 10% 경고 및 15% 복구 경계는
  Edge 드라이버의 `filterAlert` 속성을 사용합니다.
- 선풍기: 검증된 고장 속성이 없어 임의의 고장 조건을 만들지 않았습니다.

Edge 드라이버는 실제 MiIO 상태를 읽고 SmartThings에 올립니다. Docker 서비스는
온라인인 기기의 고장·필터 속성을 조회하고 다음 조회까지 15초를 기다립니다.
허브의 기본 20초 감지 주기와 합친 주기는 약 35초이며 네트워크 처리와 재시도로
더 늦어질 수 있습니다. Xiaomi 펌웨어 자체가
푸시를 보내는 구조는 아닙니다. 짧은 상태 변화는 조회 사이에 지나갈 수 있습니다.

정상 복구 전까지 이미 보낸 경고 종류를 저장해 반복 조회와 재시작의 중복을 억제합니다.
같은 경고의 이벤트 시각만 갱신되거나 물통·필터 경고가 번갈아 와도 각각 한 번만 보냅니다.
새 종류의 경고는 바로 보내며, 경고보다 나중 시각의 정상 상태를 실제로 조회한 뒤
재발하면 다시 보냅니다. 같은 시각의 서로 다른 값은 복구로 해석하지 않습니다.
저장된 상태나 대기 중인 알림보다 오래된 응답은 상태를 되돌리거나 재시도를 취소하지 않습니다.
실패·재시도 대기 중의 최신 관측도 저장해 재시작 뒤 오래된 정상값으로 재무장하지 않습니다.
시각 갱신은 전송 실패의 재시도 간격도 초기화하지 않습니다. HTTP 성공뿐 아니라 응답의
`2000000 / SUCCESS`를 확인한 뒤 완료로 저장합니다. 실패는 30초부터 최대 15분까지
간격을 늘려 재시도하며, 복구되거나 다른 경고로 바뀌면 이전 재시도를 취소합니다.
누락·알 수 없는 값·오프라인을 정상 복구로 해석하지 않습니다.

호환 가능한 상태 파일에 `notified` 목록이 없으면 마지막 경고만 기발송으로
처리합니다. 기록이 없는 다른 종류의 경고는 처음 조회될 때 한 번 알릴 수 있습니다.

상태 저장 실패 중에는 메모리에 중복 억제 상태를 유지하며 저장만 재시도합니다.
OAuth 갱신 후 저장에 실패하면 회전된 토큰을 메모리에 보관하고, API 요청 전에
저장을 다시 시도합니다. 저장 실패 중 프로세스가 종료되면 최신 메모리 상태는
복구할 수 없습니다. 손상된 기존 인증·상태 파일은 자동으로 삭제하지 않습니다.

전송 성공 직후 상태 파일 저장 전에 프로세스가 죽거나 HTTP 응답이 유실되면
중복 가능성이 있습니다. 확인된 멱등성 키나 휴대폰 수신 확인 API가 없어 정확히
한 번 수신을 보장할 수 없습니다. 직접 알림은 장소 멤버 전체 대상이므로 설치할 장소의 수신 대상을 확인하세요. 공개 API 지원 계약에 포함되지
않은 endpoint라는 한계와 공식 근거는 [직접 푸시 API](../smartthings/NOTIFICATIONS_API.md)에
정리했습니다.
