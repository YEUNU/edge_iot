# 알림 변경 검증 기록 — 2026-09-11

## 구현과 배포

- 호스트 회귀 테스트: `lua tests/run.lua .` — **41개 통과**.
- 패키지 빌드: `smartthings edge:drivers:package --build-only ...` 성공.
- 공백/패치 검사: `git diff --check` 통과.
- 실제 허브 설치 버전: `2026-09-11T10:40:35.699320467`.
- 기존 물리 기기의 ID를 유지한 채 프로필 업데이트 확인.
- 통합 `Xiaomi 알림` 기기 자동 생성 및 ONLINE 확인.
- 공기청정기 필터 수명 81%, 필터 알림 normal, 기기 오류 noFault 확인.

## 기기 → 통합 알림 실측

허브 로그에서 실제 제습기 상태를 읽어 다음 메시지와 버튼 이벤트를 발행한 것을
확인했습니다. 아래는 한국 시간입니다.

| 시간 | 통합 알림 |
|---|---|
| 19:37:34 | 제습기 필터 청소 필요 |
| 19:38:15 | 제습기 물통 가득 참 |
| 19:38:35 | 제습기 필터 청소 필요로 변경 |
| 19:39:35 | 제습기 물통 가득 참 재발 |
| 19:40:07 | 앱에서 테스트 명령 수신, 테스트 이벤트 발행 |
| 19:40:15 | 제습기 필터 청소 필요로 변경 |
| 19:40:47 | 업데이트 후 드라이버 재시작, 시작 자체로 버튼 이벤트를 발행하지 않음 |
| 19:41:13 | 제습기 물통 가득 참 |
| 19:41:35 | 제습기 필터 청소 필요로 변경 |

동일 상태의 반복 폴링에서는 버튼 이벤트가 추가되지 않았고, 물통 가득 참과
필터 청소 상태가 서로 바뀔 때 각각 새 이벤트가 발행됐습니다. 필터 청소 오류가
현재 남아 있으므로 물통을 비우는 것만으로 모든 오류가 정상으로 돌아오지는 않습니다.

## 기기 매핑 근거

MiOT specification의 모델별 정의와 구현을 대조했습니다.

- `xiaomi.derh.13l`: service 2 / property 2에 fault 0~9의 매핑이 구현과 일치.
  released v1과 debug v2 모두 해당 fault enum은 동일.
- `zhimi.airp.cpa4`: service 2 / property 2의 fault는 0 정상, 2 모터 막힘,
  3 센서 연결 끊김. service 4 / property 1의 필터 수명은 0~100%, step 1.
- `zhimi.fan.za5`: 조회한 모델 정의에서 해당 fault 속성을 제공하지 않음.

근거: [MiOT 모델 목록](https://miot-spec.org/miot-spec-v2/instances?status=all),
[제습기 v2](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:dehumidifier:0000A02D:xiaomi-13l:2),
[공기청정기 v1](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-cpa4:1).

## 푸시 전송

- 사용자가 SmartThings 통합 알림 루틴을 설정했다고 확인.
- 별도 직접 API 시험: `POST /v1/notification`, `AUTOMATION_INFO` → HTTP 200 / SUCCESS.
- 사용자가 ‘직접 API 테스트’의 실제 휴대폰 수신을 확인.
- 사용자가 현재 배포 코드의 루틴을 통한 실제 휴대폰 푸시 수신도 확인.

직접 API 시험은 배포된 드라이버의 자동 전송 경로를 대체하지 않았습니다.
조사 결과와 인증 갱신 고려 사항은 [NOTIFICATIONS_API.md](NOTIFICATIONS_API.md)에 있습니다.
서버 응답과 휴대폰 수신을 구분해서 검증했으며, 자동 테스트 및 실제 연동 검증 후
main 반영 조건을 충족했습니다. 센서·모터 등의 고장은 실제로 유발하지 않았고
공식 MiOT 매핑과 모의 입력으로 검증했습니다.
