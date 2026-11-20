# Tuya IR 코드셋 수집 및 검증 도구

이 폴더는 오프라인 IR 코드셋 수집과 검증에만 사용합니다. Docker 이미지에 포함하지 않으며 실행 중인 브리지나 SmartThings 드라이버에서 호출하지 않습니다. 인증값·요청 저널·콘솔 로그는 Git에서 제외한 `tuya-local/bridge/data/`에 저장합니다.

## 수집 범위

삼성 16개, LG 16개, 캐리어 35개, 위니아 6개(브랜드 간 공유 인덱스 포함 **71개 코드셋, 7,723개 키**, `KOREAN_SCOPE.json`)와 실기 확인 Carrier 코드셋 `104800501`을 포함해 총 72개 코드셋을 사용합니다.

## 목록 조회와 신호 확보

```sh
python3 tuya-local/commissioning/inventory_cloud.py --data tuya-local/bridge/data --rules
python3 tuya-local/commissioning/export_korean_brands.py --data tuya-local/bridge/data
python3 tuya-local/commissioning/export_korean_brands.py --data tuya-local/bridge/data --send --hub-covered
```

- 실제 수집(`--send --hub-covered`)은 IR 송신부를 가리고 본체 통풍을 확보한 상태에서 실행합니다.
- 온도·모드·풍량 키는 에어컨 조합 API로, 단일 버튼 키는 실제 key ID로 전송합니다.
- 수집 중 Tuya 오프라인 오류(30003) 발생 시 자동 재개는 `resume_korean_export.py --data tuya-local/bridge/data --hub-covered`를 사용합니다(최대 3회, 15분 대기 후 LAN/클라우드 연속 정상 확인 시 재개).

## 콘솔 로그 대조 및 카탈로그 생성

Tuya 개발자 콘솔의 Publish 로그를 `korean-console-*.json`에 저장한 뒤 대조하고 카탈로그를 생성합니다.

```sh
python3 tuya-local/commissioning/join_korean_logs.py --data tuya-local/bridge/data
python3 tuya-local/commissioning/build_korean_catalog.py --data tuya-local/bridge/data --output tuya-local/bridge/data/korean-staging
```

누락 키가 남으면 재수집 후 대조·생성을 반복합니다.

```sh
python3 tuya-local/commissioning/recapture_korean_gaps.py --data tuya-local/bridge/data
python3 tuya-local/commissioning/recapture_korean_gaps.py --data tuya-local/bridge/data --send --hub-covered
```

## 배포 검증

```sh
python3 tuya-local/commissioning/verify_korean_release.py tuya-local/bridge/catalog --require-existing
```

71개 인덱스와 7,723개 키의 누락·중복, 공유 인덱스의 브랜드 연결, 로컬 송신 형식, `104800501` 포함 여부를 검증합니다. UI 배포 도구(`deploy_ui.py`)도 이 검사를 통과해야 실행됩니다.
