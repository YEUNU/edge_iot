# 최초 샤오미 로그인으로 허브에 등록

등록할 때만 이 Mac에서 로그인 도우미를 실행합니다. Xiaomi Home 앱의 QR 승인으로
계정에 등록된 지원 기기와 로컬 토큰을 조회합니다. 허브가 실제 기기에 인증한 뒤
토큰을 내부 저장소에 보관합니다. 평소 제어에는 도우미·Mac·샤오미 클라우드가 필요 없습니다.

현재 지원 모델: `zhimi.fan.za5`, `zhimi.airp.cpa4`, `xiaomi.derh.13l`.
새 기기 추가 또는 기기 초기화로 토큰이 바뀌면 도우미를 다시 실행해야 합니다.
최초 Xiaomi Home 등록/네트워크 설정 자체를 대신하는 기능은 아닙니다.

## 실행

SmartThings CLI에 기존 계정으로 로그인돼 있어야 합니다. 앱에서 Xiaomi Edge
드라이버를 설치하고 주변 검색으로 `Xiaomi 기기 설정` 항목을 준비합니다.

```sh
python3.11 -m venv xiaomi-miio/onboarding/.venv
xiaomi-miio/onboarding/.venv/bin/pip install -r xiaomi-miio/onboarding/vendor/requirements.txt
xiaomi-miio/onboarding/.venv/bin/python xiaomi-miio/onboarding/onboard.py
```

`QR_READY`에 표시된 로컬 이미지 파일을 열어 Xiaomi Home 앱으로 스캔하고 승인합니다.
기본적으로 모든 지역을 조회합니다. 앱 지역을 알고 있으면 `--region cn` 등으로
조회 범위를 좁힐 수 있습니다. 설정 항목이 여러 개면 `--setup-device <기기 ID>`를 지정합니다.
사용자에게 토큰·IP를 복사해 입력하도록 요구하지 않습니다.

## 전송과 저장

- 샤오미 계정 비밀번호는 받지 않습니다. 계정 세션과 기기 토큰은 도우미 메모리에만
  존재하며 파일·로그로 내보내지 않습니다. QR 파일은 로그인 종료 시 삭제됩니다.
- SmartThings에는 임시 전송키만 명령으로 전달합니다. 이 키는 120초 후 만료됩니다.
  Custom capability의 sensitive 옵션은 SmartThings에서 허용되지 않아 임시 키는
  플랫폼 명령 로그에 나타날 수 있습니다. 실제 기기 토큰은 해당 명령에 포함되지 않습니다.
- 도우미와 허브 사이에는 기존 miIO 암호화 패킷(AES-CBC 및 keyed MD5 checksum)을
  HTTP 본문으로 사용합니다. HTTPS 전송은 아닙니다. 지정한 허브 IP의 인증된 요청만
  한 번 처리하고, 완료 확인 또는 만료 후 수신 서버를 종료합니다.
- 허브는 DID·모델 및 암호화된 로컬 응답을 확인한 기기만 저장·등록합니다.
  오래된 IP·잘못된 토큰·지원하지 않는 모델은 성공으로 처리하지 않습니다.
- `등록 요청`은 비동기 SmartThings 기기 생성 요청을 뜻합니다. 실제 생성·ONLINE 여부는
  앱 또는 API에서 추가 확인해야 합니다. 기존 기기는 ID를 유지하며 인증값을 갱신합니다.

## 외부 코드

QR 로그인과 계정 조회는 MIT 라이선스의
[PiotrMachowski/Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)
고정 커밋을 사용합니다. `vendor/UPSTREAM.md`와 `vendor/LICENSE`를 참조하세요.
원본 CLI의 토큰 출력 기능을 실행하지 않고 QR connector만 사용합니다.

## 검증

```sh
xiaomi-miio/onboarding/.venv/bin/python -m unittest discover -s tests -p test_xiaomi_onboarding.py -v
lua tests/run.lua .
lua tests/test_xiaomi_discovery.lua .
```

전송 codec 변조 거부, 만료, 재사용 차단, 지원 기기 필터, 실제 Python HTTP 서버 ↔
Lua 암호화 전송·등록 로직을 검증합니다. 실제 계정 로그인 및 실물 허브 결과는
`smartthings/LOCAL_DISCOVERY.md`에 별도로 기록합니다.
