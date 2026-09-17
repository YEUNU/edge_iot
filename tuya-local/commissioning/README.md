# 최초 데이터 확보 도구

이 폴더는 최초 코드 수집과 검증에만 사용합니다. Docker 이미지에 포함하지 않으며, 실행 중인 브리지나 SmartThings 드라이버에서 호출하지 않습니다. Tuya API 연결은 이 수집 단계에서만 필요합니다. 인증값·요청 저널·콘솔 로그는 Git에서 제외한 `bridge/data/`에 저장합니다.

## 수집 범위

대상 허브의 Tuya 에어컨 목록 중 삼성 16개, LG 16개, 캐리어 35개, 위니아 6개를 사용합니다. 브랜드 간 공유 인덱스를 합치면 **71개 코드셋, 7,723개 키**입니다. 정확한 목록은 `KOREAN_SCOPE.json`에 있습니다. 다른 브랜드는 배포 대상에서 제외하며, 기존에 작동을 확인한 Carrier 코드셋 `104800501`은 추가로 유지합니다.

목록 조회나 API 성공 응답만으로 로컬 지원이 완료되지는 않습니다. 각 키의 실제 `send_ir` 원문을 확보하고 검증해야 합니다. 실제 에어컨과의 호환성은 해당 기기에서 모드·온도·풍량·전원 등을 시험해야 확인할 수 있습니다.

## 목록과 신호 확보

```sh
python3 tuya-local/commissioning/inventory_cloud.py --data tuya-local/bridge/data --rules
python3 tuya-local/commissioning/export_korean_brands.py --data tuya-local/bridge/data
```

첫 명령은 4개 브랜드의 코드 목록을 조회하며 IR 신호를 보내지 않습니다. 두 번째 명령은 전송 계획만 확인합니다. 실제 수집은 **허브를 불투명하게 가리고 전원·Wi-Fi를 유지한 상태**에서 실행합니다.

```sh
python3 tuya-local/commissioning/export_korean_brands.py --data tuya-local/bridge/data --send --hub-covered
```

온도·모드·풍량 키는 에어컨 조합 API로 보냅니다. `key_id=0`인 상태 키를 일반 raw API로 보내면 성공 응답이어도 같은 신호가 반복되므로 사용하지 않습니다. 명령에 없는 온도나 풍량 차원은 임의로 추가하지 않습니다. 기타 단일 키는 실제 key ID를 사용합니다.

요청 전후 시각과 결과를 비공개 저널에 기록합니다. 응답이 불확실한 요청은 자동 재시도하지 않으며, 거절된 요청은 원인을 확인해야 합니다. 요청 사이에는 초 단위 로그를 구분할 수 있도록 간격을 둡니다. 동시에 두 수집기를 실행하지 마세요.

## 콘솔 로그 대조

Tuya 개발자 콘솔에서 수집 구간의 Publish 로그를 읽어 `korean-console-*.json`에 저장합니다. 파일은 `time`과 파싱된 `command`를 가진 객체의 배열입니다. 원문에는 추가 프레임(`key2` 등)이 있을 수 있으므로 `head`와 `key1`만 추출하지 말고 명령 전체를 보관해야 합니다.

```sh
python3 tuya-local/commissioning/join_korean_logs.py --data tuya-local/bridge/data
python3 tuya-local/commissioning/build_korean_catalog.py --data tuya-local/bridge/data --output tuya-local/bridge/data/korean-staging
```

대조기는 요청 시작부터 응답까지의 시간 구간을 사용합니다. 하나의 로그 시간이 여러 요청에 걸치거나 원문이 여러 개이면 추측해서 연결하지 않습니다. 임시 카탈로그의 `index.json`에는 모든 키를 확보한 코드셋만 포함됩니다. 임시 폴더에 남은 개별 gzip 파일만 보고 완료 여부를 판단하지 마세요.

주 수집이 끝나고 해당 구간의 로그를 모두 저장한 뒤에도 누락이 남으면 다음 명령으로 재수집합니다. 허브는 계속 가려 둡니다.

```sh
python3 tuya-local/commissioning/recapture_korean_gaps.py --data tuya-local/bridge/data
python3 tuya-local/commissioning/recapture_korean_gaps.py --data tuya-local/bridge/data --send --hub-covered
```

재수집 로그도 콘솔에서 저장한 다음 대조기와 카탈로그 생성기를 다시 실행합니다. 재수집 결과는 별도 저널로 남으며, 기존에 확보한 원문과 충돌하면 검증 실패로 남깁니다.

## 배포 조건

```sh
python3 tuya-local/commissioning/verify_korean_release.py tuya-local/bridge/data/korean-staging
# 기존 Carrier 코드셋을 함께 배치한 최종 카탈로그 검사
python3 tuya-local/commissioning/verify_korean_release.py tuya-local/bridge/catalog --require-existing
```

검사는 71개 인덱스와 7,723개 키의 누락·중복, 공유 인덱스의 브랜드 연결, 로컬 송신 형식을 확인합니다. 범위 밖 코드셋이 남거나 일부 키만 확보했다면 실패합니다. UI 배포 도구도 최종 검사를 통과해야 실행됩니다.

전원 전환·온도 증감 버튼만 제공하는 코드셋은 버튼형 화면을 사용합니다. 절대 온도나 실제 전원 상태를 만들어 표시하지 않습니다. 상태 조합을 제공하는 코드셋은 일반 에어컨 제어와 추가 버튼을 함께 제공합니다. IR은 단방향이므로 화면 상태는 기기에서 읽은 값이 아닌 마지막 송신 기준입니다.

`export_cloud.py`는 기존 Carrier 코드 확보에 사용한 도구입니다. `COVERAGE.json`은 범위를 좁히기 전의 전체 목록 조사 기록이며, 현재 지원 범위나 로컬 제어 완료를 뜻하지 않습니다.

## 연결 끊김 후 자동 재개

```sh
python3 tuya-local/commissioning/resume_korean_export.py --data tuya-local/bridge/data --hub-covered
```

수집 중 Tuya의 명시적 오프라인 오류(30003)가 발생하면 마지막 실패부터 최소 15분 쉬고, LAN과 Tuya 온라인 상태가 1분 간격으로 3회 정상일 때 재개합니다. 요청 응답 후 최소 5초, 20개마다 추가 15초 휴식을 유지합니다. 자동 재개 시도는 비공개 체크포인트에 누적해 최대 3회로 제한합니다. 다른 오류·불확실한 응답·중복 저널은 자동으로 넘기지 않습니다. 오프라인으로 거절된 키는 누락 상태로 보존하며 최종 재수집해야 합니다.

이 기능은 허브 온도를 측정하지 않습니다. 발열 시 실행을 중단하고 식힌 뒤 사용해야 합니다. IR 송신부만 가리고 본체의 통풍은 확보하세요. 감독 프로그램과 수집기는 각각 파일 잠금으로 중복 실행을 막습니다. 주 요청 완료 후에도 로그 수집·대조·누락 재수집·배포 검증은 별도로 남습니다.
