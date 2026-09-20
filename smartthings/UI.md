# Xiaomi SmartThings 화면 구성

기존 기기 ID와 capability 계약을 유지하고, 모델별 device configuration을 적용합니다.

- 제습기: 기본 화면의 현재 습도는 간결한 읽기 전용 숫자, 목표 습도는 40–70% 조절 슬라이더이며 운전 모드보다 먼저 배치.
  표준 습도 capability는 대시보드·기록·자동화에 유지하고, 큰 그래프는 고급 화면에서 표시.
- 공기청정기: 미세먼지와 필터 잔량을 표시하고 중복 필터 경고 행은 숨김.
  필터 교체 초기화는 고급 화면의 별도 관리 버튼으로 제공. 꺼진 상태에서도 저장된 수동 풍량(1–14)을 표시.
  운전 모드가 수동일 때만 풍량 슬라이더를 활성화하며 자동·수면에서는 비활성화.
  기존 자동화 호환을 위해 내부 모드 값 `즐겨찾기`는 유지하고 화면에서는 `수동`으로 표시.
- 선풍기: 바람 세기 → 바람 모드 → 좌우 회전 → 꺼짐 예약 순서.
  회전은 고정·좌우 회전만 제공하는 드롭다운이며 표준 자동화 명령과 같은 제어·확인 경로를 사용.
- 꺼짐 예약: 선풍기 0–480분, 제습기 0–720분 슬라이더. 0분은 해제이며 실제 남은 분을 그대로 표시.
- Xiaomi 알림: 최근 메시지와 테스트 버튼만 표시. 이전 루틴용 버튼 상태는 숨김.
- 대시보드: 실제 가전은 표준 switch 상태로 켜짐·꺼짐 문구와 활성/비활성 카드 색상을 표시.
  센서값은 상세 화면에서 확인하며, 알림 기기는 정적 안내 표시.

기본 화면은 자주 쓰는 기능, 고급 화면은 표시등·조작음·버튼 잠금·관리 기능을 추가합니다.
조작음과 버튼 잠금은 한 번 누르는 토글이며, 회전 각도는 ° 단위를 제목에 표시합니다.
고급 화면에서도 선풍기 꺼짐 예약이 회전 각도보다 먼저 나옵니다.
SmartThings 앱의 상태/조작 그룹 구분은 플랫폼이 결정합니다.
Android 앱은 일부 표준 capability의 `displayType`을 무시하고 전용 그래프·버튼을
사용하므로, 현재 습도와 회전 선택은 화면용 custom capability로 표시합니다.
실제 센서 값과 회전 상태를 함께 발행하며 기존 표준 capability 계약은 유지합니다.

설정용 기기는 IP·토큰 입력 전에도 온라인으로 유지합니다. 실제 가전의 연결 실패는
기존과 같이 오프라인으로 표시합니다.

## 수정과 배포

`device-configs/generate.py`가 프로필 capability를 읽어 설정 화면을 포함한 8개 JSON 구성을 만듭니다.

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

## 한국어 번역

`translations/*.json`을 capability 이름과 함께 관리합니다. Presentation의 한글
label만으로는 앱의 영문 capability 제목 대체를 방지할 수 없습니다.
정의·presentation을 등록한 다음 번역을 적용하고 device configuration을 생성합니다.

```sh
for file in smartthings/translations/*.json; do
  name=$(basename "$file" .json)
  name=${name%.*}
  smartthings capabilities:translations:upsert "earthpanel38939.$name" -i "$file"
done
```

`favoriteLevel*.json`의 실제 capability ID는 `earthpanel38939.airPurifierFavoriteLevel`입니다.
새 설치에서는 `currentHumidity`와 `fanOscillationControl`의 정의·presentation도 먼저 등록합니다.
SmartThings의 프로필 갱신 안내가 나오면 확인을 누른 뒤 기기를 다시 엽니다.
한국어 API 확인에는 `--language ko`를 사용합니다.

알림·설정 카드의 상단 제목은 Android에서 기본 언어 번역을 사용하는 동작을
실기로 확인했습니다. 이 한국어 전용 화면의 `latestAlert.en.json`과
`xiaomiLocalLink.en.json`에도 한국어 기본 제목을 넣어 영문 대체 표시를 방지합니다.

번역 형식 참고: [SmartThings Capability Translations](https://developer.smartthings.com/docs/devices/capabilities/capability-translations/).

## 실기 검증과 앱 제약

[UI_AUDIT.md](UI_AUDIT.md)에 기본·고급 화면, 실제 명령 왕복, 화면 모드별 검증 결과를 기록합니다.
관리 버튼의 `state.label` 안내는 생성된 presentation에 포함되지만 현재 Android 앱은
`pushButton` 상태 자리에 `-`를 표시합니다. 버튼 제목과 접근성 이름으로 동작을 구분하며,
앱이 결정하는 카드 간격·색상·아이콘 모양은 드라이버에서 임의로 바꾸지 않습니다.
필터 초기화는 실제 교체·청소 후에만 실행해야 합니다.

## 매뉴얼 반영 (2026-09-20)

제습기 목표 습도는 옷 건조 모드에서 조절할 수 없으며 실제 보고값을 유지합니다.
고급 화면에 종료 후 내부 건조, 건조 남은 시간, 예열 상태를 추가했습니다.
공기청정기 수동 풍량은 0–14이며 0도 켜진 상태의 저장 설정입니다.
필터 교체 초기화는 전원이 꺼진 대기 상태에서만 사용할 수 있습니다.
기기별 근거와 실측 한계는 [매뉴얼 대조 기록](MANUAL_AUDIT.md)에 있습니다.
