# Xiaomi 알림 조건

Docker 알림 서비스가 실제 기기 이름으로 SmartThings 푸시를 보내며, 알림을 누르면 해당 기기 화면이 열립니다. 설치·관리는 [알림 서비스 안내](../notification-service/README.md)를 참고하세요.
지원 모델은 `xiaomi.derh.13l` 제습기와 `zhimi.airp.cpa4` 공기청정기입니다.

**Xiaomi 알림** 기기는 최근 경고 메시지와 테스트 보내기 버튼을 제공합니다. 직접 푸시에 별도 루틴 설정은 필요 없으며, 테스트 버튼은 실제 기기의 고장이나 필터 상태를 변경하지 않습니다.

## 알림 대상

| 기기 | 조건 | 안내 내용 |
|---|---|---|
| 제습기 | `deviceFault.fault = waterFull` | 물통이 가득 찼어요. 물통을 비우고 다시 장착해 주세요. |
| 제습기 | `deviceFault.fault = filterClean` | 필터 청소가 필요해요. 필터를 확인해 주세요. |
| 제습기 | `sensorFault1`, `sensorFault2`, `commFault1`, `fanMotor`, `overload`, `lackOfRefrigerant` | 센서·내부 통신·팬 모터·과부하·냉매 오류별 점검 안내 |
| 공기청정기 | `filterAlert.status = replace` | 필터 수명이 10% 이하예요. 교체할 필터를 준비해 주세요. |
| 공기청정기 | `deviceFault.fault = motorStuck` 또는 `sensorLost` | 모터 고장 또는 센서 연결 오류 안내 |

위 custom capability의 전체 ID에는 [`integration.json`](../integration.json)의 namespace와 `.` 접두사가 붙습니다.
모델별 capability·속성·정확한 푸시 문구는 [`notifier.py`의 `CONDITIONS`](../notification-service/notifier.py)에서 단일 정의합니다.
정상(`noFault`)과 제상 중(`defrost`)은 알림 대상에서 제외합니다. 선풍기는 고장·필터 속성이 없으며, 켜짐/꺼짐·목표 습도 도달·미세먼지 변화는 기본 알림에 포함하지 않습니다.

## 상태 처리

- 허브는 20초마다 기기 핵심 상태를 읽고, Docker 알림 서비스는 클라우드 조회 후 15초를 기다립니다.
- 온라인 기기의 유효한 경고만 전송하며 누락·실패·알 수 없는 값으로 경고를 해제하지 않습니다.
- 필터 경고는 수명 10% 이하에서 시작하고 15% 초과에서 해제합니다.
- 같은 경고의 시각 갱신·반복 조회·컨테이너 재생성은 새 알림을 만들지 않습니다.
- 새 종류의 경고는 즉시 보내며, 미해결 경고는 종류별 마지막 전송 성공부터 24시간마다 재알림합니다.
- 경고보다 나중 시각의 유효한 정상 상태를 조회하면 재무장하므로 복구 후 재발 시 다시 알립니다.
- 제습기에 필터 청소 경고가 지속되는 경우 온라인 `filterClean`을 5분 연속 확인하면 만수(`waterFull`) 알림을 재무장합니다.
- 실패한 전송은 30초~15분 간격으로 재시도하며, 그 사이 복구된 경고는 취소합니다.
- 상세 운영 기준은 [알림 서비스 안내](../notification-service/README.md#알림-조건)와 [직접 푸시 API](NOTIFICATIONS_API.md)에 있습니다.

## 검증

```sh
lua tests/run.lua .
python3 -m unittest discover -s tests -p 'test_notifier*.py'
```
