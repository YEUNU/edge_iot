# SmartThings 직접 푸시 API

[Docker 알림 서비스](../notification-service/README.md)는 `POST https://api.smartthings.com/v1/notification`으로 기기별 푸시를 보냅니다.
SmartThings 루틴 없이 기기 이름을 제목으로, 해당 기기의 SmartThings ID를 `deepLink.id`로 사용합니다. 전송 성공은 HTTP 200과 응답 본문의 `{"code":2000000,"message":"SUCCESS"}`를 모두 확인합니다.

## API 구분

| 경로 | 요청과 인증 | 사용 범위 |
|---|---|---|
| 일반 Rules | `api.smartthings.com/v1/rules` | 일반 `Action` 규격에 `notification` 동작 없음 |
| Enterprise Rules | `enterprise.smartthings.com/rules`, v2 Accept 헤더, Enterprise Service Account 인증 | `notification.push` 및 `NotificationTarget.userUuids` 지원 |
| SDK 직접 알림 | `api.smartthings.com/v1/notification`, Bearer 인증 | 이 서비스가 사용하는 `type`·`messages`·`deepLink` 형식 |

## 요청 형식

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

- 공식 SDK의 `NotificationsEndpoint.create()`에 대응하며, 지정한 장소(`locationId`)에 속한 모바일 앱 전체로 전달됩니다.
- 토큰은 소스나 로그에 기록하지 않습니다.

## 실행과 인증

- Edge 드라이버는 LAN의 MiIO 상태를 읽어 SmartThings 속성으로 발행하고, Docker 알림 서비스가 속성을 조회해 푸시를 전송합니다. Edge LAN 권한은 사설 주소 범위로 제한되므로 REST API 호출은 Docker 서비스가 담당합니다.
- 설치 스크립트는 전용 SmartThings CLI 프로필의 OAuth 인증을 서비스 데이터 디렉터리로 이관합니다. refresh token은 알림 서비스 컨테이너 하나만 갱신하며, 새 토큰은 API 요청 전에 원자적으로 저장합니다.

## 한계

- `/notification` endpoint는 공식 SDK에 구현되어 있으나 공개 SmartThings OpenAPI 문서에는 포함되지 않습니다.
- 멱등성 키와 휴대폰 수신 확인 API가 없으므로 성공 응답 유실 또는 저장 직전 종료 시 알림이 중복될 수 있습니다. `SUCCESS`는 서버 수락을 의미합니다.
- 상세 중복 억제·재알림 규칙은 [알림 조건](ALERTS.md)에 있습니다.

## 참고 자료

- [SmartThings API](https://developer.smartthings.com/docs/api/public/) / [OpenAPI](https://swagger.api.smartthings.com/public/st-api.yml)
- [SmartThings Core SDK — NotificationsEndpoint](https://github.com/SmartThingsCommunity/smartthings-core-sdk/blob/main/src/endpoint/notifications.ts)
- [SmartThings CLI — OAuth 구현](https://github.com/SmartThingsCommunity/smartthings-cli/blob/main/src/lib/login-authenticator.ts)
