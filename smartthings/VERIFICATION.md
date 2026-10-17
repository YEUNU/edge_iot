# 검증과 배포 확인

자동 검사는 모의 전송·SDK·루프백 서버를 사용합니다. 실제 허브 설치, 가전 동작,
모바일 UI, 휴대폰 푸시 도착은 각각 별도로 확인합니다. 검사 명령은 저장소 루트에서 실행합니다.

## 자동 검사

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
python3 scripts/check_public_data.py --staged
git diff --check
```

- Xiaomi: 암호화·DID·속성 일치, 잘못된 응답, 연결 교체, 순차 명령과 오래된 폴링 차단,
  등록 재시도·중복 방지, 묶음 크기·수명·일회용 전송을 검사합니다.
- Tuya: 원문 IR 전체 재생, 프로필 전환·복원, 지원 조합 선택, 상태 조회 재연결,
  불확실한 명령의 중복 송신 방지, UI 수명주기를 검사합니다.
- 알림: 경고 종류별 중복 억제·24시간 재알림, 필터 경고 5분 연속 확인 후 만수 재무장,
  재시작 시 재알림 시각 유지·확인 구간 초기화, 정상 복구 시각, 재시도, OAuth 회전·저장 실패,
  감시 기기별 상태 검사와 설치 경로 처리를 검사합니다.

## 배포 확인

1. [README 배포 절차](../README.md#배포)로 패키지 빌드 및 기존 채널·허브 설치를 실행합니다.
2. 허브의 설치 버전이 업로드한 버전과 같은지 확인합니다. 기존 기기 ID·프로필·인증값이
   유지되고 주기적 조회 후 실제 기기가 ONLINE인지 확인합니다.
3. Docker를 갱신할 때 인증·설정·상태 파일을 유지합니다. 컨테이너 코드가 검증한 소스와
   일치하는지 확인하고, 서로 다른 조회 주기에서 Tuya 상태와 알림 health가 정상인지 확인합니다.
   알림 로그·조회 시각·재시도·상태 저장 확인은 [배포 후 확인](../notification-service/README.md#배포-후-확인)을 따릅니다.
4. 화면 정의 변경은 서버 presentation과 기존 기기의 presentationId를 대조합니다.
   [모바일 확인 항목](UI_AUDIT.md)은 실제 앱에서 따로 확인합니다.
5. 실제 제어를 검증할 때는 변경 전 값을 보관하고, SmartThings 명령 뒤 암호화된 LAN
   조회와 클라우드 상태가 일치하는지 기다립니다. 시험 후 원래 설정을 복원합니다.

필터 초기화·물통 채움·센서나 모터 고장을 자동 배포 검사에서 유발하지 않습니다.
알림의 API 성공은 휴대폰 수신과 구분합니다. 실제 수신은 사용자 확인 또는 휴대폰에서
확인하며, 일반 배포의 상태 조회를 위해 테스트 푸시를 보낼 필요는 없습니다.
기기별 근거는 [동작 규칙](MANUAL_AUDIT.md), 연결 범위는 [로컬 검색](LOCAL_DISCOVERY.md),
푸시 조건은 [알림 동작](ALERTS.md)에 있습니다.
