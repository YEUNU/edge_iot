# 개인·가정 데이터 비공개 유지

기기 자격증명, 계정 세션, 가정의 기기·장소 ID, 클라우드 원본 추출 파일, 패킷 캡처, 스크린샷, 로컬 런타임 데이터는 커밋하지 않습니다.
로컬 설정과 상태는 `.gitignore` 대상인 `data/`, `state/`, `.state/`, `.env`에만 보관하고, 예시 파일에는 자리표시자만 둡니다.

## 커밋·배포 전 검사

```sh
python3 scripts/check_public_data.py
python3 scripts/check_public_data.py --staged
python3 scripts/check_public_data.py --staged --metadata
gitleaks git . --redact
```

- 추적 파일과 커밋 가능한 미추적 파일(또는 `--staged` 시 Git 인덱스 전체)을 검사합니다.
- `.gz` 카탈로그는 압축을 풀어 검사하며, 비공개 경로·개인 홈 디렉터리 경로(`/Users/...`, `/home/...`)를 차단합니다.
- `--staged`는 Git 인덱스 내용을 직접 읽으므로 작업 트리를 비워도 이미 스테이징된 유출을 감지합니다.

## 비교 기준

무시된 로컬 JSON 설정과 `.env` 파일에서 토큰·키·계정/기기/장소/허브 ID·숫자 DID·LAN IP·MAC 주소를 수집해 정확히 대조합니다.

- 저장소 내 지원 JSON 파일명: `config.json`, `cloud.json`, `credentials.json`, `auth.json`, `devices.json`, `tinytuya.json`, `secrets.json`, `known_hubs.json`, `ir-detail.json`, `ac-detail.json`
- 자동 참조하는 외부 macOS 설정 경로:
  - `~/Library/Application Support/@smartthings/cli/credentials.json`
  - `~/Library/Application Support/@smartthings/cli/known_hubs.json`
  - `~/Library/Application Support/Xiaomi Notifications/auth.json`
  - `~/Library/Application Support/Xiaomi Notifications/config.json`
- 추가 비공개 파일은 `--private-config PATH` 옵션으로 지정합니다.
- 공개 OAuth 클라이언트 ID, 카탈로그 버튼 ID·IR 페이로드, 공개 SmartThings capability namespace 및 presentation ID는 비공개 값이 아닙니다.
- 결과에는 파일명과 사유만 출력하며 실제 값은 출력하지 않습니다.

## 커밋 메타데이터

커밋 이메일은 GitHub `users.noreply.github.com` 주소를 사용합니다. `--metadata`는 도달 가능한 모든 커밋의 author/committer 이메일을 검사합니다.
