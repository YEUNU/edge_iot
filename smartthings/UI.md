# Xiaomi SmartThings 화면 구성

기존 기기 ID와 capability 계약을 유지하고, 모델별 device configuration을 적용합니다.

- 제습기: 현재 습도는 읽기 전용 숫자, 목표 습도는 30–70% 조절 슬라이더.
- 공기청정기: 미세먼지와 필터 잔량을 표시하고 중복 필터 경고 행은 숨김.
  필터 교체 초기화는 고급 화면에서 단일 버튼으로 제공.
- 선풍기: 풍량은 슬라이더, 회전은 실제 지원하는 고정·좌우만 선택.
- 꺼짐 예약: 0–600분 슬라이더. 0분은 해제이며 실제 남은 분을 그대로 표시.
- Xiaomi 알림: 최근 메시지와 테스트 버튼만 표시. 이전 루틴용 버튼 상태는 숨김.
- 대시보드: 모델별 핵심 측정값 하나와 전원 조작. 알림 기기는 정적 안내 표시.

기본 화면은 자주 쓰는 기능, 고급 화면은 표시등·부저·잠금·관리 기능을 추가합니다.
SmartThings 앱의 상태/조작 그룹 구분은 플랫폼이 결정합니다.

## 수정과 배포

`device-configs/generate.py`가 프로필 capability를 읽어 7개 JSON 구성을 만듭니다.

```sh
python3 smartthings/device-configs/generate.py
smartthings presentation:device-config:create -i smartthings/device-configs/PROFILE.json -j
```

반환된 `presentationId`를 해당 `xiaomi-miio/profiles/PROFILE.yml`의 `metadata.vid`에
반영하고 `metadata.mnmn`은 `SmartThingsCommunity`로 설정합니다. 공통 custom capability
presentation을 바꾸면 해당 presentation도 먼저 업데이트한 뒤 드라이버를 패키징합니다.

배포 후 `smartthings devices DEVICE_ID -j`의 presentationId를 확인하고
`smartthings presentation PRESENTATION_ID SmartThingsCommunity -j`로 실제 생성된
화면을 확인합니다. 앱에 이전 화면이 남아 있으면 앱을 종료하고 다시 엽니다.
