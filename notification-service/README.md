# Xiaomi 기기별 직접 알림 — Docker Compose

Docker 컨테이너에서 실행하며 SmartThings 루틴 없이 기기 이름과 기기 화면 링크로 푸시합니다. 감시 대상은 Xiaomi 제습기(`xiaomi.derh.13l`)와 공기청정기(`zhimi.airp.cpa4`)입니다.

## 설치 및 구성 변경

Mac에 Python 3.9+, SmartThings CLI, Docker Compose가 필요합니다. 전용 프로필로 로그인한 뒤 설치 스크립트를 실행합니다.

```sh
smartthings locations -p xiaomi-alerts
python3 notification-service/install.py \
  --location LOCATION_ID \
  --device DEHUMIDIFIER_ID --device PURIFIER_ID \
  --test-device XIAOMI_ALERTS_ID
```

- `install.py`는 전용 CLI 프로필의 OAuth 토큰을 데이터 디렉터리(`~/Library/Application Support/Xiaomi Notifications`)의 `auth.json`과 `config.json`에 저장하고, `notification-service/`에서 `docker compose up -d --build`로 컨테이너를 실행합니다.
- 실행 코드는 저장소의 `notification-service/` 단일 경로에서 빌드하며 데이터 디렉터리에는 런타임 상태(`auth.json`, `config.json`, `state.json`, `health.json`)만 보관합니다.
- 구성을 변경할 때는 `docker compose --project-directory notification-service stop` 후 위 명령을 다시 실행합니다.

## 운영 및 상태 확인

```sh
cd notification-service
docker compose ps
docker compose logs --tail 50 -f
docker compose exec -T notifier python /app/healthcheck.py /data/health.json
docker compose restart
```

- `restart: unless-stopped`로 자동 복구됩니다.
- Docker healthcheck는 각 감시 기기와 테스트 기기의 마지막 정상 조회가 120초 이내이고 대기 중인 전송 실패나 상태 저장 실패가 없는지 확인합니다.
- SmartThings 앱의 **Xiaomi 알림 → 테스트 보내기** 버튼으로 푸시 동작을 확인할 수 있습니다.

## 알림 조건

상세 경고 문구와 조건은 [`notifier.py`](notifier.py)의 `CONDITIONS`와 [알림 조건](../smartthings/ALERTS.md)에 정의되어 있습니다.

- **제습기**: 물통 가득 참(`waterFull`), 필터 청소(`filterClean`), 센서·통신·팬 모터·과부하·냉매 부족 오류. 정상(`noFault`)과 제상(`defrost`)은 제외.
- **공기청정기**: 모터 고장(`motorStuck`), 센서 오류(`sensorLost`), 필터 수명 10% 이하(`replace`, 15% 초과 시 해제).
- **중복 억제 및 재알림**: 새 경고는 즉시 알리고, 미해결 경고는 마지막 전송 성공부터 24시간마다 재알림합니다. 제습기는 온라인 `filterClean`만 5분 연속 확인되면 다음 만수(`waterFull`) 알림을 재무장합니다. 전송 실패 시 30초~15분 간격으로 재시도합니다.
