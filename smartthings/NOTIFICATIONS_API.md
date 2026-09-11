# SmartThings 직접 푸시 API 조사 — 2026-09-11

## 결론

일반 Rules API에서 푸시 동작을 만들 수 없는 것과 모든 직접 푸시 API를
사용할 수 없는 것은 다릅니다. 실제 계정에서 `POST /v1/notification`에
`AUTOMATION_INFO` 요청을 보내 HTTP 200 및 `{"code":2000000,"message":"SUCCESS"}`를
받았습니다. 이 요청은 앱 루틴을 실행하지 않았습니다. 이후 사용자가 휴대폰에
**‘직접 API 테스트’가 도착했다**고 확인했으므로 이번 직접 전송은 서버 응답과
실제 수신 양쪽에서 검증됐습니다.

## 세 경로의 차이

| 경로 | 규격과 인증 | 이번 확인 결과 |
|---|---|---|
| 일반 Rules | `api.smartthings.com/v1/rules` | `notification` action을 HTTP 422로 거부 |
| Enterprise Rules | `enterprise.smartthings.com/rules`, `Accept: application/vnd.smartthings+json;v=2`, Enterprise Service Account 인증 | 규격에 `notification.push` 존재. 현재 CLI 인증으로 읽기 요청은 HTTP 403 |
| SDK 직접 알림 | `api.smartthings.com/v1/notification`, Bearer 인증, `type` + `messages` | `AUTOMATION_INFO` 시험 요청은 HTTP 200 / SUCCESS |

## 처음 Rules 요청이 실패한 이유

일반 API의 `Action` 정의에는 `notification` 항목이 없습니다. 반면 Enterprise
API의 `Action`에는 `notification`과 `NotificationAction`, `PushNotification`,
개별 수신자 지정용 `NotificationTarget.userUuids`가 있습니다. Enterprise
문서의 예제를 일반 Rules 경로에 넣었기 때문에 다음 오류가 반환됐습니다.

```text
HTTP 422 ConstraintViolationError
target: notification
Unrecognized field "notification"
```

이 응답은 휴대폰 알림 권한 문제도, MiIO 통신 문제도 아닙니다. `notification`
필드가 해당 API의 action 모델에 없다는 뜻입니다. JSON 들여쓰기나 일반
Rules 권한을 고치는 것으로 이 기능 차이를 해결할 수 없습니다.

일반 Rules의 전체 action 집합은 SDK 타입보다 공식 OpenAPI가 더 넓습니다.
따라서 지원 여부를 SDK 타입만으로 판단하지 않고, 현재 공식 OpenAPI 원본과
실제 서버 응답을 대조했습니다. 두 규격 모두에서 확인한 결정적 차이는
일반 `Action`에 `notification`이 없다는 점입니다.

## 직접 알림에서 성공한 요청 형식

아래 ID는 예시 자리표시자입니다. 토큰은 소스나 로그에 넣지 않습니다.

```http
POST https://api.smartthings.com/v1/notification
Authorization: Bearer <access-token>
Content-Type: application/json
```

```json
{
  "locationId": "<location-id>",
  "type": "AUTOMATION_INFO",
  "messages": [
    {
      "default": {
        "title": "직접 API 테스트",
        "body": "루틴을 거치지 않고 보낸 테스트입니다."
      },
      "ko_KR": {
        "title": "직접 API 테스트",
        "body": "루틴을 거치지 않고 보낸 테스트입니다."
      }
    }
  ],
  "deepLink": {
    "type": "device",
    "id": "<alert-device-id>"
  }
}
```

이것은 Enterprise의 `notification.push.message` 형식과 다른 API입니다.
SDK의 `NotificationsEndpoint.create()`가 사용하는 형식입니다. 이번 계정의
현재 CLI OAuth 인증에는 이름에 `notif`가 들어가는 scope가 없었지만 위 요청은
성공했습니다. 이 관찰을 모든 앱·토큰·알림 타입에 동일하게 적용하지 않습니다.

SDK는 장소에 속한 모바일 앱들을 대상으로 보낸다고 설명하며, 이 요청 형식에는
Enterprise의 `userUuids` 수신자 필드가 없습니다. 이번 시험은 사용자가 해당
장소의 멤버가 본인 한 명이라고 확인한 뒤 진행했습니다. 멤버가 늘어나면
본인에게만 보낸다는 기존 전제를 다시 확인해야 합니다.

## 지원 상태와 자동화에 남는 문제

- **Mac에서 성공한 API 요청을 Edge 드라이버에서 그대로 실행할 수는 없습니다.**
  SmartThings 개발자 지원팀은 2025-02-10에도 Edge 드라이버에 인터넷 접근이 없어
  SmartThings REST API를 호출할 수 없다고 명시했습니다. LAN 권한은 사설 주소
  범위 통신을 허용하며 인터넷 접근 권한이 아닙니다. HTTPS 모듈이나 OAuth
  자동 갱신 코드를 추가하는 것만으로 이 실행 환경 제한이 해결되지는 않습니다.
- SDK에 코드가 있고 이번 요청도 성공했으므로 **직접 전송이 불가능하다는
  설명은 부정확**합니다.
- 2021년 개발자 지원팀은 SDK 기반의 예제를 안내했습니다. 그러나 2025년
  지원 답변에서는 이 endpoint가 공개 API 문서에 포함돼 있지 않아 안정 동작을
  지원 대상으로 보장하지 않는다고 설명했습니다. 두 시기의 안내를 구분해야 합니다.
- 이번 시험은 현재 로그인된 CLI OAuth access token을 메모리에서 읽어 전송했습니다.
  토큰을 기기 설정·저장소에 복사하지 않았습니다. 해당 토큰은 만료되므로 이것을
  그대로 하드코딩한 Edge 드라이버는 장기 자동 알림 구현이 아닙니다.
- 직접 자동 전송을 제품 경로로 사용하려면 별도 인증/갱신 관리, 실패 재시도,
  수신 대상 관리가 필요합니다. CLI와 허브에 같은 refresh token을 복제하면
  토큰 갱신 주체가 충돌할 수 있으므로 독립 인증 설계를 검토해야 합니다.
- 이전 배포는 `기기 → Xiaomi 알림 버튼 → 루틴 → 푸시`였습니다. 새 경로는
  `기기 → 확정된 SmartThings 속성 → Mac의 Docker 서비스 → 직접 푸시`입니다.
  드라이버는 이전 루틴의 버튼 이벤트를 더 이상 보내지 않습니다.

## 루틴 없는 기기별 알림으로 변경할 때의 구조

사용자에게 보이는 알림의 제목을 실제 기기 이름으로 하고 `deepLink.id`를 해당
기기의 SmartThings ID로 지정할 수 있습니다. 다만 전송 프로그램은 Edge 밖의
항상 실행되는 서버/NAS 또는 컴퓨터에서 동작해야 합니다. Mac에서 실행한다면
종료·잠자기 동안 전송이 중단되므로 허브만으로 동작하는 구현이라고 설명해서는
안 됩니다. Xiaomi 기기 자체의 펌웨어를 변경하는 작업도 아닙니다.

사용자는 이 Mac을 서버로 사용한다고 확인했습니다. 독립 OAuth 세션과 갱신,
확정된 상태 변화별 중복 억제, 복구된 경고의 취소, 전송 실패 재시도는
[Mac 알림 서비스](../notification-service/README.md)에 구현했습니다. 새 경로를
실제로 검증하기 전에 기존 루틴 경로를 제거하거나 새 경로의 완료를 선언하지
않습니다. 전용 로그인과 OAuth 갱신, 갱신된 토큰의 재사용을 검증했습니다. 사용자는
‘제습기’ 제목의 직접 푸시 수신과 제습기 화면 연결을 확인했습니다. Docker에서도
갱신과 실제 필터 청소 경고 전송 성공을 확인했습니다. 구체적인 배포 검증은
[VERIFICATION.md](VERIFICATION.md)에 기록합니다.

## 확인한 1차 자료

1. [일반 SmartThings API](https://developer.smartthings.com/docs/api/public/)
   및 해당 페이지가 사용하는 [OpenAPI 원본](https://swagger.api.smartthings.com/public/st-api.yml):
   `definitions.Action`, `/rules`, `PermissionConfig` 확인. `w:notifications`는
   설정 예시에 존재하지만 `/notification` endpoint 계약은 이 규격에 없습니다.
2. [Enterprise 자동화의 추가 기능](https://developer.smartthings.com/docs/enterprise/enterprise-api-overview/automations/about):
   일반 API와 차이 및 `Notification` 동작을 명시.
3. [Enterprise API](https://developer.smartthings.com/docs/api/enterprise)와
   [OpenAPI 원본](https://developer.smartthings.com/docs/api-refs/enterprise-v2.yml):
   별도 host, v2 Accept 헤더, `Action.notification`, `PushNotification`, `NotificationTarget` 확인.
4. [Enterprise 접근](https://developer.smartthings.com/docs/enterprise/api-access/access),
   [서비스 계정](https://developer.smartthings.com/docs/enterprise/api-access/service-accounts/about),
   [가입 안내](https://developer.smartthings.com/docs/enterprise/get-started/introduction):
   Enterprise 회원 및 Service Account/API key/JWT 절차 확인.
5. [공식 SDK 직접 알림 구현](https://github.com/SmartThingsCommunity/smartthings-core-sdk/blob/main/src/endpoint/notifications.ts):
   `AUTOMATION_INFO`, `messages`, `deepLink`, `notification` endpoint 확인.
6. [공식 SDK Rules 구현](https://github.com/SmartThingsCommunity/smartthings-core-sdk/blob/main/src/endpoint/rules.ts):
   Rules action 타입과 OAuth principal별 조회 범위 확인.
7. [개발자 지원팀의 2021년 직접 알림 예제 안내](https://community.smartthings.com/t/automation-smartapp-permission-problem/219823/5)
   및 [당시 REST API 논의](https://community.smartthings.com/t/notifications-on-rest-api/221042).
8. [개발자 지원팀의 2025년 5월 직접 API 지원 범위 답변](https://community.smartthings.com/t/notifications-api-with-new-pat-token-after-refresh/300038).
9. [개발자 지원팀의 2025년 7월 일반 Rules 푸시 미지원 답변](https://community.smartthings.com/t/notification-with-smartthings-api/241890/27).
10. [최신 API Access App 설정](https://developer.smartthings.com/docs/service-integrations/app-setup),
    [릴리스 노트](https://developer.smartthings.com/docs/release-notes):
    새 API Access App의 이벤트 알림은 webhook 수신을 뜻하며 휴대폰 푸시와 다름.
11. [개발자 지원팀의 2025년 Edge 인터넷 접근 제한 설명](https://community.smartthings.com/t/pointers-for-a-virtual-edge-device-connecting-to-physical-devices/295041/3).
12. [SmartThings 엔지니어의 LAN 권한과 사설 주소 제한 설명](https://community.smartthings.com/t/edge-drivers-private-addresses-lan/257846):
    외부 전송에는 LAN 프록시 등 허브 밖의 실행 환경이 필요함.
13. [공식 CLI OAuth 구현](https://github.com/SmartThingsCommunity/smartthings-cli/blob/main/src/lib/login-authenticator.ts):
    프로필별 인증 저장, PKCE 로그인, 만료 전 refresh token 갱신 확인.
