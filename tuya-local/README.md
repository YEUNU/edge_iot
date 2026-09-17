# Tuya 에어컨 로컬 제어

SmartThings Edge → LAN HTTP 브리지 → Tuya IR 허브 → 적외선 에어컨.
브리지는 상시 켜진 Mac/서버에서 실행합니다. 실행 중 Tuya 클라우드 API를 호출하지 않습니다.
스마트싱스 앱과 계정 서비스 자체의 인터넷 요구 사항은 별개입니다.

## 지원 범위와 수집 상태

대상은 이 IR 허브에 Tuya가 제공하는 삼성 16개, LG 16개, 캐리어 35개, 위니아 6개 코드셋입니다. 브랜드 사이의 공유 항목을 합치면 **71개 코드셋, 7,723개 키**입니다. 기존에 실제 작동을 확인한 Carrier `104800501`도 유지합니다. 그 외 브랜드는 새 배포에서 제외합니다.

**4개 브랜드의 71개 코드셋·7,723개 키 원문 확보와 대조가 완료됐습니다.** 기존 Carrier를 합쳐 72개 코드셋을 포함합니다. 최종 배포는 모든 원문 키와 브랜드 연결 검사를 통과해야 합니다. 브리지·드라이버 배포와 실제 휴대폰 화면 검증을 완료했습니다. [수집 절차](commissioning/README.md)와 [검증 기록](TEST_RESULTS.md)을 참고하세요.

기존 Carrier는 냉방/난방 18–30°C × 풍량 4종, 자동/송풍/제습 각 1종 = 107개 켜짐 상태와 전원 끄기를 포함합니다. **107은 기종 수가 아니라 이 리모컨 하나의 설정 조합 수입니다.**

하나의 코드셋이 여러 모델과 호환될 수 있습니다. Tuya 목록에 있다는 사실만으로 실제 에어컨의 모든 기능이 동작한다고 보장하지 않습니다. 온도·모드·풍량·전원과 필요한 추가 버튼을 실제 기기에서 확인해야 합니다.

## 앱에서 사용하기

1. 허브에 드라이버를 설치하고 **기기 추가 → 주변 검색**으로 `Tuya 에어컨 로컬`을 추가합니다.
2. 저장소 루트에서 `python3 tuya-local/bridge/connect_smartthings.py`를 한 번 실행합니다. 로그인된 SmartThings CLI의 기기와 `.env`의 LAN 주소를 찾아 자동 연결합니다. 앱에 토큰을 복사하지 않습니다. 여러 기기가 있으면 `--device ID --address LAN_IP`로 지정합니다.
3. 평소에는 전원·설정 온도·모드·풍량을 표시하고 아래에 기종 설정을 둡니다. 기종 교체 시 `기종 설정` 버튼 또는 ⋮ → 설정 → 에어컨 기종 변경을 사용합니다.
4. 제조사·기종을 고른 뒤 시험 전원·시험 온도·시험 모드·시험 풍량으로 실제 반응을 확인합니다. 시험 중에는 모든 제어가 저장 전 후보 기종에 적용됩니다.
5. `반응 확인 · 기종 저장`을 누르면 선택을 허브에 저장하고 기본 화면으로 돌아갑니다. `변경 취소`는 기존 기종을 유지합니다. 평소 화면과 시험 화면의 모드·풍량은 목록에서 고릅니다. 루틴에는 표준 전원·온도·모드·풍량 capability를 유지합니다.

기종 선택만으로 신호를 보내지는 않습니다. 시험 전원이나 온도·모드·풍량 조작은 실제 신호를 보냅니다.
모바일 앱에서 화면 전환 후 “기기 성능이 변경되었습니다” 안내가 뜨면 확인을 누르고 에어컨을 다시 여세요. 기종 저장 후에도 같은 절차로 기본 화면을 엽니다. 원형 버튼 옆의 `-` 표시는 SmartThings의 상태 없는 버튼 표현입니다.
시험할 때는 IR 허브의 가림을 제거하고 에어컨을 향하게 둡니다.
온도/모드/풍량을 변경하면 전체 켜짐 프레임을 보내므로 에어컨이 켜집니다.
모드 전환 시 이전 풍량/온도가 없으면 그 모드에서 가장 가까운 지원 조합을 사용합니다.

IR은 단방향입니다. 표시 상태는 마지막으로 보낸 명령이며 실제 온도나 작동 확인값이 아닙니다.
재시작/기종 전환 후 실제 전원 상태는 미확인입니다. 기종별 마지막 온도·풍량·모드는 복원하지만 전원이 켜졌다고 추정하지 않습니다. 다른 리모컨으로 조작하면 앱 표시와 달라질 수 있습니다.
저장 전에 시험 컨트롤로 필요한 온도·풍량·모드를 확인하세요. 전원 반응만으로 모든 기능의 호환성을 보장하지 않습니다.
전원 전환·온도 증감 버튼만 제공하는 코드셋은 버튼형 화면을 사용합니다. 버튼을 고르는 동작은 송신하지 않으며, 보내기를 눌러야 신호가 나갑니다. 이런 기종의 절대 온도·전원 상태는 표시하지 않습니다. 상태 조합형 기종의 추가 기능은 `리모컨 버튼 더보기`에서 선택합니다.
목록에 없는 기종은 추가 코드 확보가 필요합니다.

## 브리지 설치

```sh
cd tuya-local/bridge
mkdir -p data state
chmod 700 data state
cp config.example.json data/config.json
chmod 600 data/config.json
# 실제 IR 허브의 device_id, local_key, ip, api_token을 설정합니다.
# api_token: 영문/숫자 32자 이상. 예: python3 -c 'import secrets; print(secrets.token_hex(32))'
TUYA_BIND_IP=192.168.1.100 TUYA_UID=$(id -u) TUYA_GID=$(id -g) docker compose up -d --build
```

포트는 신뢰하는 LAN IP에만 바인딩하세요. HTTP bearer 인증이며 TLS는 사용하지 않습니다.
Docker가 실행되어 있어야 하고 Mac이 잠자면 제어가 중단됩니다. IP는 공유기에서 DHCP 예약을 권장합니다.
`remote_index`로 내장 코드셋을 선택할 수 있습니다. `codes`가 설정돼 있으면 그 명시적 코드가 우선합니다.
설정과 클라우드 내보내기 자료는 `bridge/data/`에만 저장하며 Git과 Docker 이미지에서 제외합니다.
Docker에는 `data/config.json` 파일 하나만 읽기 전용으로 마운트합니다. 클라우드 인증·내보내기 파일은 컨테이너에 노출하지 않습니다.

`bridge/state/`에는 기종별 설정과 일회용 연결 티켓의 소비 기록을 저장합니다. Git과 이미지에서 제외합니다.
자동 연결은 120초 동안 유효한 기기별 일회용 티켓을 기존 SmartThings 계정으로 전달합니다.
허브가 LAN에서 티켓을 교환하여 브리지 인증값을 저장하며, 사용한 티켓은 재사용할 수 없습니다.
브리지 인증값은 LAN 명령의 권한 확인용입니다. 드라이버와 브리지 재시작 후에도 수동 입력 없이 연결됩니다.
주소가 바뀌면 자동 연결 스크립트를 다시 실행하세요.

일반 Python 실행:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python service.py check --config data/config.json
.venv/bin/python service.py serve --config data/config.json --bind 192.168.1.100 --state-dir state
```

`check`는 IR 학습 종료 메시지로 LAN 채널을 깨운 뒤 응답을 확인하며 IR을 방사하지 않습니다.
브리지 하나는 물리 허브 하나와 에어컨 하나를 대상으로 합니다. 여러 에어컨은 별도 인스턴스/포트를 사용하세요.

## 코드와 UI 재생성

현재 카탈로그는 Tuya에서 사용자 허가로 송신한 Publish 원문을 보존합니다. 다른 공개 라이브러리의 신호를 변환하는 코드는 제거했습니다. `head`, `key1`뿐 아니라 `key2` 등 추가 프레임도 그대로 전송합니다.

```sh
python3 commissioning/verify_korean_release.py bridge/catalog --require-existing
python3 bridge/build_ui.py
python3 bridge/build_temperature_ui.py
python3 bridge/build_remote_ui.py
python3 bridge/deploy_ui.py
smartthings edge:drivers:package . --channel YOUR_CHANNEL --hub YOUR_HUB
```

`deploy_ui.py`는 로그인한 계정의 capability/presentation을 생성·갱신하고 프로필의 `vid`를 저장합니다. 다른 계정에 배포할 때는 프로필, 생성기, Lua와 연결 스크립트의 `earthpanel38939`를 자신의 namespace로 변경하세요. 일상 화면은 9종 온도 범위와 버튼형 기종 전용 프로필을 사용합니다. 상태 조합형 기종은 표준 전원·온도·모드·풍량 루틴을 유지합니다. 버튼형 12개 코드셋은 명시적 버튼 전송을 사용합니다.

## 검증

```sh
python3 -m unittest discover -s tests -p 'test_tuya*.py' -v  # 저장소 루트에서
lua tests/test_tuya_client.lua
lua tests/test_tuya_ux.lua
luac -p tuya-local/src/init.lua tuya-local/src/client.lua tuya-local/src/catalog.lua
smartthings edge:drivers:package --build-only /tmp/tuya-local.zip tuya-local
```

테스트는 실제 기기에 IR을 보내지 않습니다.
- 카탈로그 명령을 모의 Tuya 전송 계층으로 재생하고 저장된 원본 payload와 비교합니다. 새로운 Tuya 원문은 추가 프레임을 포함한 모든 필드를 유지해야 합니다.
- 모드별 지원 조합 선택, 잘못된 입력 차단, 전원 끄기 후 설정 유지, 기종별 설정 분리와 재시작 복원을 검사합니다.
- 동시 요청의 기종 분리, 응답 유실과 복구, 인증 누락·만료·재사용·다른 기기의 연결 티켓을 검사합니다.
- 실제 Lua HTTP 클라이언트를 모의 소켓으로 실행하여 분할 전송, 연결 실패, 잘린 응답, 비정상 JSON, 과대 응답, 오류 상태 코드를 검사합니다.
- Edge 화면 전환, 기종 탐색의 무전송, 시험과 저장의 분리, 취소, 연결 복구 및 명령 대기열을 검사합니다.

실제 설치에서 자동 연결 티켓 교환, Edge 명령 → LAN 브리지 → Tuya 허브 응답, 웹 온도 표시와 기종별 범위를 확인했습니다.
SmartThings 웹은 모바일 presentation을 완전히 구현하지 않으며 일부 라벨은 영어이고 사용자 정의 시험 버튼은 표시되지 않을 수 있습니다. 기종 시험·저장은 모바일 앱을 기준으로 구성했습니다.
2026-09-16 실제 Galaxy 스마트싱스 앱에서 한글 제목, 온도·모드·풍량 배치, 기종 목록과 저장을 확인했습니다. 앱에서 냉방 26°C·보통 풍량을 조작하고 전원을 껐으며, 사용자가 실제 에어컨의 켜짐·설정 변경·꺼짐 반응을 확인했습니다.

## Tuya 서버와 실행 서비스 분리

`commissioning/` 도구는 최초 데이터 확보용이며 Docker 이미지와 실행 서비스에서 제외합니다. `inventory_cloud.py --data bridge/data --rules`는 이 허브에 제공되는 에어컨 제조사·리모컨 인덱스·API 코드 레코드를 읽기 전용으로 수집합니다. 목록이나 API 코드 레코드만 확보한 항목은 검증된 로컬 코드북과 구분하며 선택 UI에 자동 추가하지 않습니다.

브리지의 `inspect`, `check`, `serve`는 설정된 허브 IP의 6668 포트 외 발신 연결을 프로세스 수준에서 거부합니다. DNS를 통한 외부 호스트 접속도 거부합니다. 공유기 설정이나 IR 허브 펌웨어 자체의 인터넷 연결은 변경하지 않습니다. SmartThings 계정/앱 서비스는 별개입니다.
