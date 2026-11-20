# SmartThings 화면 구성

모든 가전(공기청정기·선풍기·제습기·에어컨)은 동일한 7단계 위계와 라벨 규칙을 따릅니다.

1. **전원** (`switch`)
2. **운전 모드** (모든 가전 공통 라벨 `운전 모드`, 선택지 명시)
3. **핵심 제어** (강도·목표 슬라이더: 수동 풍량, 바람 세기, 목표 습도, 설정 온도)
4. **부가 운전·예약** (좌우 회전 → 회전 각도 → 꺼짐 예약)
5. **현재 상태·센서** (간결한 상태 카드: 초미세먼지, 현재 습도, 현재 온도, 필터 잔량, 기기 상태, 동작 시 건조·예열)
6. **본체 설정** (고급 화면: 표시등 → 조작음 → 버튼 잠금 → 종료 후 내부 건조)
7. **관리 버튼** (필터 초기화, 에어컨 기종 변경·리모컨 버튼 더보기)

## 기기별 세부 규칙

- **공기청정기**: 운전 모드(자동/수면/수동, 내부 값 `즐겨찾기`) → 수동 풍량(0–14, 수동 모드 시 활성) → 초미세먼지(`㎍/㎥`) → 필터 잔량(`%`) → 기기 상태. 필터 교체 초기화는 고급 화면의 전원이 꺼진 대기 상태에서 활성화됩니다.
- **선풍기**: 운전 모드(자연풍/직선풍) → 바람 세기(0–100%) → 좌우 회전(고정/좌우 회전) → 회전 각도(30–120, 회전 시 활성) → 꺼짐 예약(0–480분) → 현재 습도(`%`) → 현재 온도(`°C`).
- **제습기**: 운전 모드(스마트/수면/옷 건조) → 목표 습도(40–70%, 스마트·수면 시 활성) → 꺼짐 예약(0–720분) → 현재 습도(`%`) → 현재 온도(`°C`) → 기기 상태. 건조 남은 시간과 예열 상태는 실제 동작 중일 때만 고급 화면에 표시됩니다.
- **에어컨**: 운전 모드 → 설정 온도(기종별 범위) → 바람 세기 → 기기 상태 → 에어컨 기종 변경 / 리모컨 버튼 더보기.
- **Xiaomi 알림**: 최근 메시지와 테스트 보내기 버튼만 표시합니다.
- **대시보드**: 실제 가전은 표준 `switch` 상태로 켜짐·꺼짐 문구와 카드 색상을 표시합니다. 설정 기기는 IP·토큰 입력 전에도 온라인을 유지합니다.

## 생성과 배포

다른 계정에 배포할 때는 먼저 [배포 설정과 검증](../README.md#배포-설정과-검증)에 따라 `integration.json`을 수정합니다.

`device-configs/generate.py`가 Xiaomi 프로필 capability를 읽어 8개 JSON 구성을 생성합니다.

```sh
python3 smartthings/device-configs/generate.py
smartthings presentation:device-config:create -i smartthings/device-configs/PROFILE.json -j
```

반환된 `presentationId`를 해당 `xiaomi-miio/profiles/PROFILE.yml`의 `metadata.vid`에 반영하고 `metadata.mnmn`은 `SmartThingsCommunity`로 설정합니다. Tuya UI는 `tuya-local/bridge/build_ui.py`와 `deploy_ui.py`로 생성·배포합니다.

## 한국어 번역

`translations/*.json`을 capability 정의·presentation 등록 후 적용합니다.

```sh
namespace=$(python3 -c 'import json; print(json.load(open("integration.json"))["namespace"])')
for file in smartthings/translations/*.json; do
  name=$(basename "$file" .json)
  name=${name%.*}
  smartthings capabilities:translations:upsert "$namespace.$name" -i "$file"
done
```

알림·설정 카드의 상단 제목 영문 대체 표시를 방지하기 위해 `latestAlert.en.json`과 `xiaomiLocalLink.en.json`에도 한국어 기본 제목을 유지합니다.

기기별 세부 동작 규칙은 [기기별 동작 규칙](MANUAL_AUDIT.md)을 참고하세요.
