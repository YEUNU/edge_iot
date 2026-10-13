# 샤오미 3종 동작 규칙과 근거

대상은 `zhimi.fan.za5`, `zhimi.airp.cpa4`, `xiaomi.derh.13l`입니다.
Tuya 에어컨 동작은 별도의 [Tuya 안내](../tuya-local/README.md)를 따릅니다.

## 근거와 적용 범위

- [Mi Smart Standing Fan 2 공식 매뉴얼](https://cdn.azams0.fds.api.mi-img.com/xiaomi-b2c-i18n-upload/User-Guide-Upload-mi.com/Personal_Care/30663-Mi-Smart-Standing-Fan2-UserGuide-EU.pdf), 인쇄면 6–7: 전원, 풍속, 자연풍/직선풍, 회전, 이전 설정 유지, 앱 꺼짐 예약 8시간.
- [Xiaomi Smart Air Purifier 4 Compact 공식 매뉴얼](https://user-guide2024.cnbj1.mi-fds.com/user-guide2024/Hong%20Kong/A1/Xiaomi%20Smart%20Air%20Purifier%204%20Compact%20User%20Manual%20%28EN%29.pdf), 인쇄면 4, 6–7: 자동/수면/수동, 표시등 3단계, 버튼 잠금, 필터 교체와 대기 중 초기화.
- [Xiaomi Smart Dehumidifier Lite 공식 매뉴얼](https://cdn.azams0.fds.api.mi-img.com/xiaomi-b2c-i18n-upload/EU-ERP-Userguide-upload/Environment-Appliances/55631-Xiaomi-Smart-Dehumidifier-Lite-UserGuide-EU.pdf), 인쇄면 4–5: 스마트/수면/옷 건조, 습도 40–70%, 12시간 예약, 종료 후 40분 내부 건조, 물통 경고, 제상.
- [제습기 공식 지원 안내](https://www.mi.com/global/support/faq/details/KA-227417/): 최초 전원 연결 시 스마트 50%, 옷 건조에서 습도 수동 변경 불가.
- [제습기 공식 제품 설명](https://www.mi.com/hk/product/xiaomi-smart-dehumidifier-lite/): 앱 목표 습도 40–70%, 1% 단위.

지역별 매뉴얼과 펌웨어의 원시 데이터 범위가 다르다. 사용자 조절 범위에는
매뉴얼을 적용하고, 기본값·모드 전환·타이머·건조 진행 상태는 기기가 반환한 값을
사용한다. 공장 초기화·네트워크 초기화·물리적 청소/설치 절차는 원격 명령으로
추가하지 않았다. 제상, 압축기 보호, 장시간 운전 보호는 기기 펌웨어가 담당한다.

MiOT 모델 정의로 속성 주소, 단위, 열거형, 읽기/쓰기 권한을 별도 대조했다:
[선풍기 v2](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:fan:0000A005:zhimi-za5:2),
[공기청정기 v1](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-cpa4:1),
[제습기 v2](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:dehumidifier:0000A02D:xiaomi-13l:2).

## 기능 대조

| 기기 | 기능 | 적용 및 확인 |
|---|---|---|
| 공통 | 전원·모드·조작음·표시등·버튼 잠금 | 해당 모델의 MiOT 값을 사용. 버튼 잠금은 본체 조작 잠금이며 원격 앱 잠금으로 확대하지 않음 |
| 선풍기 | 자연풍/직선풍, 0–100 풍량 | 0은 전원 끄기, 1–100은 운전 설정. 잘못된 숫자·회전 모드 거절 |
| 선풍기 | 좌우 회전, 30–120° | 수직 회전 명령 거절. 수직 각도는 본체에서 조절 |
| 선풍기 | 전원 복귀·모드 연동 | 전원 확인 시 저장 풍량/모드/회전도 재조회. 모드 변경 시 풍량 재조회 |
| 선풍기 | 꺼짐 예약 | 설정 0–480분, 0은 취소. MiOT 상한 600분보다 매뉴얼 상한을 우선. 초→분 변환, 확인 중 경과한 초 허용 |
| 공기청정기 | 자동/수면/수동 | 자동 제어는 기기에 맡김. 기존 루틴 값 ‘즐겨찾기’를 유지하고 화면에는 ‘수동’ 표시 |
| 공기청정기 | 수동 풍량 | MiOT 0–14. 실제 기기가 0을 전원 켜짐 상태에서 저장함을 확인. 0을 전원 끄기로 해석하지 않음 |
| 공기청정기 | PM2.5·필터·고장 | 기기 측정값 사용. 10% 사전 알림/15% 재무장 기준은 드라이버 정책이며 제조사 필터 소진 표시 기준으로 주장하지 않음 |
| 공기청정기 | 필터 초기화 | 실제 대기 상태를 조회한 뒤 교체 초기화 명령 허용. 교체 후에만 초기화 실행 |
| 제습기 | 스마트·수면 목표 습도 | 40–70%, 1% 단위. 변경 직전에 실제 모드를 조회, 실패하거나 옷 건조이면 쓰지 않음 |
| 제습기 | 모드별 목표 습도 | 모드와 목표를 함께 재조회. 기본값을 고정하지 않아 저장 설정과 펌웨어 변경을 보존 |
| 제습기 | 옷 건조 | 습도 조절을 비활성화하고 실제 반환값을 표시. 40%를 강제로 쓰지 않음 |
| 제습기 | 꺼짐 예약 | 0–720분. 서비스 8의 활성화/시간/남은 시간 사용. 활성화가 60분으로 초기화하므로 켠 뒤 시간을 설정 |
| 제습기 | 종료 후 내부 건조 | 서비스 7/속성 1로 설정. 남은 초(7/2)를 분으로 올림 변환. 예약 시간(8/3)과 구분 |
| 제습기 | 예열·제상·물통·필터 청소 | 실제 상태 표시. 제상은 고장 푸시로 처리하지 않고 기존 고장 구분·중복 억제 유지 |

## 상태 확인과 검증 범위

기기별 쓰기 명령은 확인까지 순서대로 처리합니다. 명령 전에 시작된 폴링 결과는
최신 상태를 덮어쓰지 않도록 버립니다. 모드 변경 후 목표 습도는 기기가 반환한 값을
사용하며 앱 표시나 예상 기본값으로 덮어쓰지 않습니다.

제습기 타이머는 활성화할 때 시간이 초기화되는 동작에 맞춰 먼저 활성화하고 시간을
설정합니다. 전용 `dehumidifierTimer` capability로 720분을 처리하고, 선풍기는
`powerOffTimer`의 화면·드라이버 상한 480분을 사용합니다.

자동 검사는 속성 매핑·경계·순차 처리·지연 응답을 검사합니다. 장시간 운전, 실제 고장,
물리적 풍량·소음·제습 성능을 증명하지 않습니다. 실기기 검증 절차는
[검증 안내](VERIFICATION.md)를 따르며, 필터 수명 초기화는 모의 검증으로 확인합니다.
