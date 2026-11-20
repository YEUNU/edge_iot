# Xiaomi SmartThings 화면 구성

모델별 device configuration으로 기본 화면과 고급 화면을 분리해 제공합니다.

- **제습기**: 기본 화면에 현재 습도(간결한 읽기 전용 숫자), 목표 습도(40–70% 슬라이더), 운전 모드, 꺼짐 예약(0–720분), 고장 상태를 배치합니다. 표준 습도·온도 capability는 간결한 상태 카드로 표시하며, 옷 건조 모드에서는 목표 습도 조절을 비활성화하고 기기 보고값을 유지합니다. 건조 남은 시간과 예열 상태는 실제 동작 중일 때만 고급 화면에 표시합니다.
- **공기청정기**: 미세먼지, 필터 잔량, 운전 모드, 수동 풍량(0–14)을 표시합니다. 수동 풍량 슬라이더는 운전 모드가 수동(내부 값 `즐겨찾기`)일 때만 활성화됩니다. 필터 교체 초기화는 고급 화면의 전원이 꺼진 대기 상태에서 표시됩니다.
- **선풍기**: 바람 세기(0–100%) → 바람 모드 → 좌우 회전(고정·좌우 회전 드롭다운) → 꺼짐 예약(0–480분) 순서로 배치합니다. 회전 각도(°) 슬라이더는 좌우 회전이 켜졌을 때만 활성화되며, 현재 습도·온도는 간결한 상태 카드로 표시합니다.
- **Xiaomi 알림**: 최근 메시지와 테스트 보내기 버튼만 표시합니다.
- **대시보드**: 실제 가전은 표준 `switch` 상태로 켜짐·꺼짐 문구와 카드 색상을 표시합니다. 설정 기기는 IP·토큰 입력 전에도 온라인을 유지합니다.
- **고급 화면**: 표시등, 조작음(토글), 버튼 잠금(토글), 회전 각도(°), 종료 후 내부 건조, 건조 남은 시간, 예열 상태, 필터 초기화 기능을 표시합니다.

## 생성과 배포

다른 계정에 배포할 때는 먼저 [배포 설정과 검증](../README.md#배포-설정과-검증)에 따라 `integration.json`을 수정합니다.

`device-configs/generate.py`가 프로필 capability를 읽어 8개 JSON 구성을 생성합니다.

```sh
python3 smartthings/device-configs/generate.py
smartthings presentation:device-config:create -i smartthings/device-configs/PROFILE.json -j
```

반환된 `presentationId`를 해당 `xiaomi-miio/profiles/PROFILE.yml`의 `metadata.vid`에 반영하고 `metadata.mnmn`은 `SmartThingsCommunity`로 설정합니다. custom capability presentation을 바꾼 경우 해당 presentation도 먼저 업데이트한 뒤 드라이버를 패키징합니다.

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
