# Xiaomi 알림 조건과 검증

## 한 번만 연결하기

드라이버 업데이트 후 **Xiaomi 알림** 기기가 자동 생성됩니다. 기존 제습기와
공기청정기는 삭제하거나 다시 추가할 필요가 없습니다.

SmartThings 앱에서 아래 루틴 **하나**를 만듭니다.

1. 조건: **기기 상태 → Xiaomi 알림 → 버튼 → 한 번 누름**.
2. 동작: **알림 보내기 → 멤버에게 알림 보내기**. 수신자는 **본인만** 선택합니다.
3. 알림 문구: `Xiaomi 기기에 확인할 사항이 있어요. Xiaomi 알림을 열어주세요.`
4. 저장한 뒤 **Xiaomi 알림 → 테스트 알림 보내기**를 누르고 휴대폰 수신을 확인합니다.

조건을 사전 조건으로 지정하지 않습니다. OS와 SmartThings 앱의 알림을 허용해야
하며 앱 버전에 따라 메뉴 이름은 다를 수 있습니다. 이후 기기를 추가하거나
알림 조건이 늘어나도 같은 루틴을 사용합니다. 아래 조건별 루틴은 따로 만들지 않습니다.

루틴의 푸시 문구는 고정됩니다. 발생 기기와 구체적인 사유는 **Xiaomi 알림 → 최근 알림**에
표시됩니다. 테스트 알림도 최근 알림에 표시되지만 실제 기기의 고장·필터 상태를 바꾸거나
초기화하지 않습니다. 여러 경고가 발생하면 각각 버튼 이벤트를 보내며 최근 알림 화면은
마지막 메시지를 표시합니다. 각 기기의 현재 오류도 기기 상세 화면에서 확인할 수 있습니다.

## 알림 대상

| 기기 | 조건 | 안내 문구 |
|---|---|---|
| 제습기 | `deviceFault.fault = waterFull` | 물통이 가득 찼어요. 물통을 비우고 다시 장착해 주세요. |
| 제습기 | `deviceFault.fault = filterClean` | 필터 청소가 필요해요. 필터를 확인해 주세요. |
| 제습기 | `sensorFault1`, `sensorFault2`, `commFault1`, `fanMotor`, `overload`, `lackOfRefrigerant` | 기기 오류가 감지됐어요. 앱의 기기 상태를 확인해 주세요. |
| 공기청정기 | `filterAlert.status = replace` | 필터 수명이 10% 이하예요. 교체할 필터를 준비해 주세요. |
| 공기청정기 | `deviceFault.fault = motorStuck` 또는 `sensorLost` | 기기 오류가 감지됐어요. 앱의 기기 상태를 확인해 주세요. |

위 custom capability의 전체 ID에는 `earthpanel38939.` 접두사가 붙습니다.
정상(`noFault`)과 제상 중(`defrost`)은 알림 대상에서 제외합니다.
선풍기는 검증된 매핑에 고장·필터 센서가 없어 임의의 오류를 만들어내지 않습니다.
켜짐/꺼짐, 목표 습도 도달, 순간적인 미세먼지 변화는 기본 알림에 포함하지 않습니다.

## 상태 처리

- 오류와 필터 수명은 20초 간격 기본 조회 대상입니다. 통신과 클라우드 전송
  시간이 추가되므로 20초 이내 휴대폰 도착을 보장하지는 않습니다.
- 동일한 오류는 반복 발행하지 않습니다. 정상 복귀 또는 다른 상태로 바뀐 뒤
  같은 오류가 다시 발생하면 새 이벤트를 발행합니다.
- 필터 수명 10% 이하에서 `replace`, 15% 초과에서 `normal`이 됩니다.
  11~15% 구간에서는 이미 발생한 교체 경고를 유지합니다.
- 누락·실패한 속성 응답은 경고를 해제하지 않습니다. 필터 수명은 0~100%
  범위의 숫자만 처리하며 잘못된 타입이나 범위 밖 값은 무시합니다.
- 알림을 통합 기기에 발행한 뒤 기기별 처리 상태를 영구 필드에 저장해 재시작 시
  반복 알림을 억제합니다. SDK 최신 속성 상태와 필터 경고의 영구 필드도 함께 사용합니다.
  루틴을 연결하기 전에 이미 발생한 이벤트는 재전송하지 않으므로 처음에는 현재 기기
  상태도 확인합니다. 허브 이벤트 발행 성공은 휴대폰 수신 확인과는 다릅니다.
- 통합 기기 생성이 지연되거나 이벤트 발행이 실패하면 해당 경고를 처리 완료로
  기록하지 않습니다. 다음 정상적인 기기 응답 때 다시 시도합니다. 그전에 실제
  기기가 정상으로 돌아오면 지난 경고를 나중에 재생하지 않습니다.
- 연결이 끊긴 동안에는 새 기기 오류를 감지할 수 없습니다. 연결 끊김 푸시는
  이 변경의 구현 범위에 포함하지 않습니다.

## 전송 경로 확인 현황

이 문서의 조건은 기기 이벤트 정의이며, 휴대폰 푸시 연결 완료를 의미하지 않습니다.
일반 Rules API에서 `notification` action 생성은 실제 계정에서 HTTP 422
(`Unrecognized field "notification"`)로 거부됐습니다. Enterprise API의
알림 예제를 일반 API에 그대로 적용할 수 없습니다.

이는 직접 알림 API 자체가 없다는 뜻은 아닙니다. 별도 `POST /v1/notification`
시험은 현재 OAuth 인증으로 HTTP 200 / SUCCESS를 받았습니다. 자세한 규격 차이와
인증 갱신 문제는 [직접 푸시 API 조사](NOTIFICATIONS_API.md)에 정리했습니다.

통합 기기는 실제 허브에 설치됐고 제습기의 필터 청소 상태로 메시지와 버튼 이벤트를
발행한 것이 확인됐습니다. 사용자가 루틴 연결 및 실제 휴대폰 푸시 수신도 확인했습니다.
검증 범위와 결과는 [검증 기록](VERIFICATION.md)에 있습니다.

## 검증 절차

```bash
lua tests/run.lua .
smartthings edge:drivers:package --build-only /tmp/xiaomi-miio-alerts.zip xiaomi-miio
```

새 `earthpanel38939.filterAlert`, `earthpanel38939.latestAlert` capability와 presentation은 드라이버 패키징 전에
등록해야 합니다. 이미 등록돼 있으면 중복 생성하지 않고 기존 정의와 비교합니다.
정의는 같은 폴더의 `capabilities/filterAlert*.json`, `capabilities/latestAlert*.json`에 있습니다.
`latestAlert`의 dashboard label은 정적 문자열을 사용합니다. 서버가 임의 문자열
속성을 dashboard에 직접 바인딩한 presentation을 403으로 거부해, 실제 메시지는
정상 등록·조회된 detailView의 state로 표시합니다.

1. 자동 테스트: 오류 코드별 매핑, 반복 억제, 복구 후 재발, SDK 상태 복원,
   프로필 변경, 필터 경계값, 잘못된 응답, 통합 기기의 비동기 생성, 발행 실패
   재시도, 여러 기기의 연속 이벤트와 테스트 명령을 검사합니다.
2. 실제 기기: LAN 응답과 SmartThings 속성이 일치하는지 확인합니다.
3. 휴대폰: 안전하게 재현 가능한 상태 변화로 푸시 1회 수신, 상태 유지 중
   중복 없음, 복구 후 재발 알림을 확인합니다. 센서·모터 고장이나 냉매 부족을
   일부러 만들지 않으며 해당 코드는 모의 입력으로 검증합니다.

실제 휴대폰 수신을 확인하기 전에는 전체 동작 완료로 판단하거나 main에 푸시하지 않습니다.

참고: [SmartThings Rules](https://developer.smartthings.com/docs/automations/rules),
[Enterprise 알림 action](https://developer.smartthings.com/docs/enterprise/enterprise-api-overview/automations/about),
[Edge 최신 기기 상태](https://developer.smartthings.com/docs/edge-device-drivers/device.html).
