# Changelog

## v1.4.0 (2026-04-11)

### Added
- GPU 자동 감지 시작 스크립트 (`start.sh`): `nvidia-smi` 존재 여부에 따라 GPU 지원 자동 활성화
- NVIDIA GPU 오버라이드 설정 (`docker-compose.gpu.yml`)

### Details
- Mac(GPU 없음)과 Ubuntu+NVIDIA(GPU 있음) 환경에서 동일한 `./start.sh`로 컨테이너 시작 가능
- GPU 환경에서는 `docker-compose.gpu.yml`이 자동으로 오버레이되어 컨테이너에서 CUDA 사용 가능

## v1.3.0 (2026-04-11)

### Changed
- VS Code CLI 설치 시 ARM64 하드코딩 제거, `TARGETARCH` 기반 멀티 아키텍처 자동 감지 (arm64/amd64)
- 프로젝트 이름 `vscode-tunnel-for-mac` -> `vscode-tunnel`로 변경
- README에서 ARM64 전용 경고 제거, 아키텍처 자동 감지 설명으로 대체

### Details
- `docker buildx` 또는 네이티브 빌드 시 호스트 아키텍처를 자동으로 감지하여 올바른 VS Code CLI 바이너리를 다운로드
- Apple Silicon(arm64)뿐 아니라 x86_64(amd64) 환경에서도 별도 수정 없이 빌드 가능

## v1.2.1 (2026-04-08)

### Added
- `docker-compose.yml`에 VS Code 원격 서버/익스텐션 데이터 영속 볼륨 추가 (`vscode-server-data:/root/.vscode-server`)
- named volume 정의에 `vscode-server-data` 추가

### Details
- 컨테이너 재시작/재생성 이후에도 원격 환경의 VS Code extension 및 서버 관련 데이터가 유지되도록 구성

## v1.2.0 (2026-04-08)

### Added
- `docker-compose.yml`에 Codex 인증 정보 공유 볼륨 추가 (`~/.codex:/root/.codex`)

### Details
- 호스트에서 로그인한 Codex 세션/설정을 컨테이너에서 재사용 가능하도록 구성
- Claude Code 인증 공유 방식(`~/.claude:/root/.claude`)과 동일한 패턴으로 적용

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
