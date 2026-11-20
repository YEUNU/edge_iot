# 샤오미 3종 동작 규칙

대상 모델은 `zhimi.fan.za5`, `zhimi.airp.cpa4`, `xiaomi.derh.13l`입니다.
Tuya 에어컨 동작은 [Tuya 안내](../tuya-local/README.md)를 따릅니다.

## 근거 자료

- [Mi Smart Standing Fan 2 공식 매뉴얼](https://cdn.azams0.fds.api.mi-img.com/xiaomi-b2c-i18n-upload/User-Guide-Upload-mi.com/Personal_Care/30663-Mi-Smart-Standing-Fan2-UserGuide-EU.pdf), 인쇄면 6–7
- [Xiaomi Smart Air Purifier 4 Compact 공식 매뉴얼](https://user-guide2024.cnbj1.mi-fds.com/user-guide2024/Hong%20Kong/A1/Xiaomi%20Smart%20Air%20Purifier%204%20Compact%20User%20Manual%20%28EN%29.pdf), 인쇄면 4, 6–7
- [Xiaomi Smart Dehumidifier Lite 공식 매뉴얼](https://cdn.azams0.fds.api.mi-img.com/xiaomi-b2c-i18n-upload/EU-ERP-Userguide-upload/Environment-Appliances/55631-Xiaomi-Smart-Dehumidifier-Lite-UserGuide-EU.pdf), 인쇄면 4–5
- [제습기 공식 지원 안내](https://www.mi.com/global/support/faq/details/KA-227417/) 및 [제품 설명](https://www.mi.com/hk/product/xiaomi-smart-dehumidifier-lite/)
- MiOT 모델 정의: [선풍기 v2](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:fan:0000A005:zhimi-za5:2), [공기청정기 v1](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-cpa4:1), [제습기 v2](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:dehumidifier:0000A02D:xiaomi-13l:2)

사용자 조절 범위는 매뉴얼을 따르고, 기본값·모드 전환·타이머·건조 진행 상태는 기기가 반환한 값을 그대로 사용합니다. 공장 초기화·네트워크 초기화·제상·압축기 보호는 원격 명령으로 노출하지 않고 기기 펌웨어에 맡깁니다.

## 기기별 동작 규칙

| 기기 | 기능 | 적용 규칙 |
|---|---|---|
| 공통 | 전원·모드·조작음·표시등·버튼 잠금 | 모델별 MiOT 속성을 사용. 버튼 잠금은 본체 조작 잠금에 한정 |
| 선풍기 | 자연풍/직선풍, 0–100% 풍량 | 0은 전원 끄기, 1–100은 운전 설정. 범위 밖 값·미지원 회전 모드 거절 |
| 선풍기 | 좌우 회전, 30–120° | 고정(`fixed`)·좌우 회전(`horizontal`)만 허용. 수직 회전 명령 거절 |
| 선풍기 | 전원 복귀·모드 연동 | 전원 확인 시 풍량·모드·회전 재조회, 모드 변경 시 풍량 재조회 |
| 선풍기 | 꺼짐 예약 | 0–480분(0은 취소). 초→분 변환, 확인 중 경과한 초 허용 |
| 공기청정기 | 자동/수면/수동 | 자동 제어는 기기에 위임. 내부 모드 값 `즐겨찾기`를 화면에 `수동`으로 표시 |
| 공기청정기 | 수동 풍량 | MiOT 0–14. 0도 켜진 상태의 유효한 저장 설정이며 전원 끄기로 해석하지 않음 |
| 공기청정기 | PM2.5·필터·고장 | 기기 측정값 사용. 필터 알림은 10% 이하 시작, 15% 초과 해제 |
| 공기청정기 | 필터 초기화 | 실제 대기(전원 꺼짐) 상태를 조회한 뒤에만 교체 초기화 허용 |
| 제습기 | 스마트·수면 목표 습도 | 40–70%, 1% 단위. 변경 직전 실제 모드를 조회해 옷 건조 모드면 거절 |
| 제습기 | 모드별 목표 습도 | 모드와 목표 습도를 함께 재조회해 기기 저장값을 보존 |
| 제습기 | 옷 건조 | 습도 조절을 비활성화하고 기기 반환값을 그대로 표시 |
| 제습기 | 꺼짐 예약 | 0–720분(`dehumidifierTimer`). 서비스 8 활성화 시 60분으로 초기화되므로 활성화 후 시간을 설정 |
| 제습기 | 종료 후 내부 건조 | 서비스 7/속성 1로 설정, 남은 초(7/2)를 분으로 올림 변환 |
| 제습기 | 필터 청소 알림 초기화 | 서비스 7/action 3(입력 없음) 단일 객체 전송 후 고장 속성 재조회 |
| 제습기 | 예열·제상·물통·필터 청소 | 실제 상태 표시. 제상(`defrost`)은 고장 푸시에서 제외 |

## 상태 확인과 직렬화

- 기기별 쓰기 명령은 확인까지 순서대로 처리합니다.
- 명령 전에 시작된 폴링 결과는 최신 상태를 덮어쓰지 않도록 폐기합니다.
- MiOT `action`은 단일 객체로 전송하고, 속성 조회·쓰기는 배열 형식을 사용합니다.
