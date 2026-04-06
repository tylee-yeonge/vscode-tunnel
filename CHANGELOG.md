# Changelog

## v1.1.0 (2026-04-06)

### Added
- `entrypoint.sh` watchdog 스크립트: 터널 프로세스 상태를 120초마다 감시하고, 좀비/중복 프로세스 발생 시 자동 복구
- Docker healthcheck 설정 (`code tunnel status` 기반)

### Changed
- `Dockerfile`의 CMD를 `entrypoint.sh` 래퍼 스크립트로 변경

### Details
- 프로세스 생존, 중복 감지, `tunnel status` 상태를 3단계로 검증
- 초기 시작 후 5분간 grace period 적용 (GitHub 인증 대기 허용)
- 복구 3회 실패 시 컨테이너 종료 → Docker `restart: unless-stopped`로 자동 재시작

## v1.0.0 (2026-04-01)

### Added
- 초기 구성: Dockerfile + docker-compose (Ubuntu 24.04 + OpenCV 4.10.0 + VS Code CLI + Claude Code)
- `.env` 기반 터널 이름 및 워크스페이스 경로 설정
- SSH 키, git config, Claude Code 인증 정보 볼륨 마운트
- `vscode-cli-data` 볼륨으로 터널 인증 상태 유지
