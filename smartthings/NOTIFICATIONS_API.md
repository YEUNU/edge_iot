# SmartThings 직접 푸시 API

Mac의 [Docker 알림 서비스](../notification-service/README.md)는
`POST https://api.smartthings.com/v1/notification`으로 기기별 푸시를 보냅니다.
SmartThings 루틴을 실행하지 않으며 제목은 기기 이름, `deepLink.id`는 해당
기기의 SmartThings ID를 사용합니다. 전송 성공은 HTTP 응답과 본문의
`{"code":2000000,"message":"SUCCESS"}`를 모두 확인합니다.

## API 구분

| 경로 | 요청과 인증 | 사용 범위 |
|---|---|---|
| 일반 Rules | `api.smartthings.com/v1/rules` | 일반 `Action` 규격에 `notification` 동작이 없음 |
| Enterprise Rules | `enterprise.smartthings.com/rules`, v2 Accept 헤더, Enterprise Service Account 인증 | `notification.push` 및 `NotificationTarget.userUuids` 지원 |
| SDK 직접 알림 | `api.smartthings.com/v1/notification`, Bearer 인증 | 이 서비스가 사용하는 `type`·`messages`·`deepLink` 형식 |

Enterprise의 `notification.push.message` 형식은 이 서비스의 요청 형식과 다릅니다.
Enterprise 예제를 일반 Rules에 넣거나 일반 Rules 권한을 바꿔 직접 알림을
구성할 수는 없습니다. API Access App의 이벤트 알림인 webhook 수신도 휴대폰
푸시와 별개입니다.

## 요청 형식

ID와 토큰은 아래 자리표시자를 실제 값으로 대체합니다. 토큰을 소스나 로그에
기록하지 않습니다.

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
        "title": "<device-label>",
        "body": "<warning-message>"
      },
      "ko_KR": {
        "title": "<device-label>",
        "body": "<warning-message>"
      }
    }
  ],
  "deepLink": {
    "type": "device",
    "id": "<device-id>"
  }
}
```

이 형식은 공식 SDK의 `NotificationsEndpoint.create()`에 대응합니다. 알림은
장소에 속한 모바일 앱을 대상으로 하며 개별 수신자를 지정하는 `userUuids`
필드는 없습니다. 설치할 장소의 멤버가 모두 수신 대상인지 확인하고, 멤버 구성이
바뀌면 수신 대상도 다시 확인해야 합니다.

## 실행과 인증

Edge 드라이버는 LAN의 MiIO 상태를 읽어 SmartThings 속성으로 올리고, Mac의
Docker 서비스가 속성을 조회해 푸시를 전송합니다. Edge의 LAN 권한은 사설 주소
통신 범위이므로 인터넷의 SmartThings REST API 호출을 드라이버 안으로 옮길 수
없습니다. Mac과 Docker가 실행 중이어야 하며 Mac의 잠자기·종료 중에는 새 경고를
전송할 수 없습니다.

설치 프로그램은 전용 SmartThings CLI 프로필의 OAuth 인증을 서비스로 이관합니다.
기본 CLI 로그인은 사용하지 않으며, 이관한 refresh token은 서비스 하나만 갱신합니다.
새 토큰은 API 요청 전에 원자적으로 저장하고 재설치할 때도 유지합니다. 갱신이나
이관 중 저장 실패에 대한 재시도와 서비스 중지 절차는
[설치·관리 문서](../notification-service/README.md)에 있습니다.

이 서비스는 특정 OAuth 세션과 `AUTOMATION_INFO` 형식을 사용합니다. 다른 앱,
토큰 종류, 알림 타입에서도 동일하게 허용된다고 가정하지 않습니다.

## 지원 범위와 한계

직접 알림 구현은 공식 SDK에 있지만 `/notification` endpoint 계약은 공개
SmartThings OpenAPI에 포함되지 않습니다. 개발자 지원팀도 공개 API 문서 밖의
endpoint에 대해 안정 동작을 보장하지 않는다고 설명합니다. SDK 구현이나 성공
응답만으로 장기 지원 계약이 있다고 해석하지 않습니다.

서비스는 경고별 중복 억제와 실패 재시도를 수행합니다. 확인된 멱등성 키와
휴대폰 수신 확인 API가 없어, 성공 응답이 유실되거나 성공 직후 상태 저장 전에
프로세스가 종료되면 중복될 수 있습니다. `SUCCESS`는 서버의 전송 수락이며
휴대폰 도착 확인은 아닙니다. 상세 상태 처리와 조회 간격의 한계는
[알림 조건](ALERTS.md)에 있습니다.

## 공식 자료

- [일반 SmartThings API](https://developer.smartthings.com/docs/api/public/) 및
  [OpenAPI 원본](https://swagger.api.smartthings.com/public/st-api.yml): 일반 Rules의
  `Action`과 공개 endpoint 규격.
- [Enterprise 자동화](https://developer.smartthings.com/docs/enterprise/enterprise-api-overview/automations/about),
  [Enterprise API](https://developer.smartthings.com/docs/api/enterprise),
  [OpenAPI 원본](https://developer.smartthings.com/docs/api-refs/enterprise-v2.yml):
  별도 host와 v2 Accept 헤더, `Action.notification`, `PushNotification`, `NotificationTarget`.
- [Enterprise 접근](https://developer.smartthings.com/docs/enterprise/api-access/access) 및
  [서비스 계정](https://developer.smartthings.com/docs/enterprise/api-access/service-accounts/about):
  Enterprise 인증 절차.
- [공식 SDK 직접 알림 구현](https://github.com/SmartThingsCommunity/smartthings-core-sdk/blob/main/src/endpoint/notifications.ts):
  `AUTOMATION_INFO`, `messages`, `deepLink`, `notification` endpoint.
- [개발자 지원팀의 직접 API 지원 범위](https://community.smartthings.com/t/notifications-api-with-new-pat-token-after-refresh/300038) 및
  [일반 Rules 푸시 미지원 설명](https://community.smartthings.com/t/notification-with-smartthings-api/241890/27).
- [API Access App 설정](https://developer.smartthings.com/docs/service-integrations/app-setup):
  webhook 이벤트 수신 설정.
- [Edge 인터넷 접근 제한](https://community.smartthings.com/t/pointers-for-a-virtual-edge-device-connecting-to-physical-devices/295041/3) 및
  [LAN 권한과 사설 주소 범위](https://community.smartthings.com/t/edge-drivers-private-addresses-lan/257846):
  Edge의 네트워크 실행 범위.
- [공식 CLI OAuth 구현](https://github.com/SmartThingsCommunity/smartthings-cli/blob/main/src/lib/login-authenticator.ts):
  프로필별 인증 저장, PKCE 로그인, refresh token 갱신.
