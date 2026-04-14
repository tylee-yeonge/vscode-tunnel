# Changelog

## v1.6.0 (2026-04-14)

### Added
- Study Timer에 Phase/Week 단위 집계 추가
  - 일별 JSON 최상위에 `by_phase_week: Record<string, number>` 필드 신설
  - 카테고리 키: `Studies/Phase N/weekM/` 하위 파일은 `Phase N/weekM`, 그 외는 모두 `other`
  - 1초 tick에서 현재 활성 에디터 경로를 기준으로 카테고리 카운터 가산
  - 불변식: `active_seconds == sum(by_phase_week.values())`
- 노트북 에디터(`activeNotebookEditor`) fallback 추가: `.ipynb` 파일도 경로 기반으로 Phase/week에 정상 누적

### Changed
- `DayFile` 스키마 확장: `by_phase_week?: Record<string, number>` (optional, 구버전 호환)

### Migration
- v1.5.0에서 생성된 기존 파일은 로드 시 `by_phase_week = {"other": <기존 active_seconds>}`로 백필
- nanobot은 `other`를 집계에서 제외하므로 과거 데이터가 새 집계에 섞이지 않음

## v1.5.0 (2026-04-14)

### Added
- Study Timer VS Code extension (`extensions/study-timer/`): `/workspace/study/visual-slam-and-perception-learning` 워크스페이스의 실사용 시간을 자동 측정
  - active 조건: 창 focus + 최근 5분 이내 활동 이벤트(편집/커서/에디터 전환/focus 복귀)
  - 1초 tick으로 active_seconds 누적, 30초 주기로 atomic write
  - 자정 경계에서 세션을 두 파일로 분할 기록
  - activate 시 같은 날 마지막 세션이 5분 이내이면 이어받기 (VS Code reload 등으로 인한 세션 중복 방지)
  - 결과는 `/root/.study-timer/YYYY-MM-DD.json`에 일별 JSON으로 저장
- `study-timer-data` named volume 추가 (nanobot-docker에서 `external: true`로 공유 가능)
- 호스트 timezone 상속:
  - `/etc/localtime`, `/etc/timezone` 읽기 전용 마운트
  - `TZ` 환경변수 추가 (기본값 `Asia/Seoul`): VS Code server Node 프로세스가 TZ env를 우선시하므로 명시적으로 설정

### Changed
- Dockerfile을 multi-stage build로 재구성: `node:20-alpine` builder에서 extension 컴파일 후 최종 이미지에 복사
- `entrypoint.sh`에 extension 배치 단계 추가: tunnel 시작 전 `~/.vscode-server/extensions/`와 `~/.vscode/extensions/`에 복사

### Fixed
- VS Code tunnel 인증 영속화 경로 수정: `vscode-cli-data` 볼륨 마운트 지점을 `/root/.vscode-cli` -> `/root/.vscode/cli`로 변경
  - 실제 인증 토큰은 `/root/.vscode/cli/token.json`에 저장되는데 기존 경로는 실효성이 없었음
  - 수정 이후 컨테이너 재시작 시 재인증 불필요

## v1.4.1 (2026-04-11)

### Changed
- README 전면 개편: 최신 프로젝트 상태 반영
  - 실행 방법을 `docker compose up` 에서 `./start.sh`로 통일
  - GPU 지원 섹션 추가 (사전 조건, 베이스 이미지 안내)
  - 볼륨 구성에 `vscode-server-data`, `~/.codex` 누락분 추가
  - 파일 구성에 `docker-compose.gpu.yml`, `start.sh` 추가
  - Mac/Ubuntu 모두 지원한다는 설명 추가

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
