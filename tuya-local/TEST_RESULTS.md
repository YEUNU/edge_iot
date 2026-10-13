# Tuya 검증 범위

현재 카탈로그는 4개 브랜드의 71개 코드셋·7,723개 원문 키와 기존 Carrier `104800501`을
포함합니다. 자동 검사는 실제 IR을 방사하지 않는 모의 전송과 SDK를 사용합니다.

## 자동 검사

```sh
python3 -m unittest discover -s tests -p 'test_tuya*.py'
lua tests/test_tuya_client.lua
lua tests/test_tuya_ux.lua
python3 tuya-local/commissioning/verify_korean_release.py tuya-local/bridge/catalog --require-existing
python3 scripts/check_public_data.py
smartthings edge:drivers:package --build-only /tmp/tuya-local.zip tuya-local
```

- 원문 키 7,723개와 상태 프레임 7,635개를 모의 장치로 재생해 payload 전체를 대조합니다.
  `key2` 등 추가 필드를 유지하며 버튼형 기종에 절대 상태를 만들어 넣지 않습니다.
- 온도·풍량을 명시하면 지원하는 정확한 조합만 전송합니다. 모드 단독 또는 전원 켜기와
  모드만 요청하면 해당 모드에서 가능한 온도·풍량을 선택합니다.
- 프로필 초기화·전환은 같은 경로로 상태와 모드·키 인덱스를 구성합니다. 잘못된 기본
  설정의 후보는 현재 기종과 상태를 바꾸지 않고 거부합니다.
- 기종별 설정 저장·재시작 복원·캐시 축출·동시 명령·저장 실패를 검사합니다.
  상태 조회 연결 복구는 재시도하되 불확실한 IR 송신은 반복하지 않습니다.
- HTTP 분할·잘린 응답·과대 응답·오류 코드·인증·일회용 티켓·기기 불일치를 검사합니다.
- 후보 선택의 무전송, 시험·저장·취소, UI 전환·연결 복구·후속 명령 큐를 검사합니다.

`python3 scripts/benchmark_tuya.py`는 72개 프로필 탐색의 메모리와 반복 UI 이벤트 비용을
측정합니다. 동적 프로필은 최근 4개를 보관하고 기본·명시적 설정 프로필을 유지합니다.
벤치마크는 모의 클라이언트를 사용하며 실물 응답 시간·전체 RSS를 뜻하지 않습니다.

## 운영 확인

브리지 컨테이너 코드·카탈로그가 검증한 소스와 같은지, `/data`에 `config.json`만
마운트되는지 확인합니다. 일회용 자동 연결 후 수동 토큰 입력 없이 주기적 상태 조회가
성공하고 SmartThings가 ONLINE인지 확인합니다. 실제 전원·온도 변경은 별도 제어 시험입니다.

화면은 [모바일 확인 항목](../smartthings/UI_AUDIT.md)에 따라 실제 앱에서 확인합니다.
카탈로그 대조는 모든 에어컨의 물리적 호환성을 증명하지 않습니다. 기종별 호환성은 실제
에어컨에서 확인해야 하며, IR 단방향 특성상 브리지 응답도 실제 작동 피드백은 아닙니다.
