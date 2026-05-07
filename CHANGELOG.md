# Changelog

## v1.7.2 (2026-05-07)

### Fixed
- study-timer 사이드카 활성화 시 `study-timer-data` 볼륨이 nginx 기본 파일
  (`index.html`, `50x.html`)로 오염되던 버그 수정
  - 원인: `docker-compose.tailscale.yml`이 볼륨을 nginx 이미지의 기본 html 경로
    `/usr/share/nginx/html`에 mount. Docker는 **빈 named volume이 처음 mount될 때
    이미지의 해당 경로 파일을 볼륨으로 복사**하므로 nginx alpine의 기본 html이
    study-timer-data 볼륨으로 들어감 (`:ro` 플래그는 mount 이후에만 적용되어
    초기 복사를 막지 못함)
  - 결과: vscode-tunnel 컨테이너의 `/root/.study-timer/`에 무관한 `index.html` /
    `50x.html`이 보이고, 사이드카 HTTP 응답에 같은 파일이 노출됨
- 사이드카 mount 경로를 nginx 이미지에 존재하지 않는 `/srv/study-timer`로 변경,
  `study-timer-nginx.conf`의 `root`도 동일하게 맞춤. 이미지에 해당 경로가 없으므로
  복사 자체가 발생하지 않음

### Migration
이미 사이드카를 활성화해 볼륨이 오염된 호스트(주로 Ubuntu)는 다음 절차로 정리:

```bash
# 1. 모든 컨테이너 정지
docker compose -f docker-compose.yml -f docker-compose.gpu.yml \
  -f docker-compose.local.yml -f docker-compose.tailscale.yml down

# 2. 오염된 볼륨 제거 (study-timer JSON이 아직 없으니 손실 없음)
docker volume rm study-timer-data

# 3. 최신 코드 pull
git pull

# 4. 정상 재기동
./start.sh
```

`study-timer-data`에 이미 의미 있는 JSON이 누적된 호스트라면 볼륨 제거 대신
오염 파일만 삭제: `docker exec vscode-tunnel rm -f /root/.study-timer/index.html /root/.study-timer/50x.html`

## v1.7.1 (2026-05-07)

### Fixed
- 권장 베이스 이미지 태그를 실제 NVIDIA Docker Hub에 발행된 조합으로 정정
  - 변경 전: `nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04` (해당 태그 미발행)
  - 변경 후: `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`
- NVIDIA Hub에서 ubuntu24.04 + cudnn-devel 변종은 12.6.0부터 발행되어 12.4 시리즈와는
  조합되지 않음을 확인
- v1.7.0 시점에 추천한 12.4.1 태그로 `./start.sh` 실행 시 발생하던 빌드 실패 해소
  (`failed to resolve source metadata: ... not found`)

### Changed
- `Dockerfile`의 주석, `.env.sample`, `README.md`, `UBUNTU_SETUP.md`의 BASE_IMAGE 안내를
  12.6.3로 일괄 갱신
- PyTorch 2.6 공식 wheel이 CUDA 12.6을 지원하므로 학습 환경 측면에서도 동등 이상의 선택

### Migration
- 기존 `.env`에 `BASE_IMAGE=nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04` 설정한 경우
  `12.6.3`으로 교체 후 `./start.sh` 재실행
- `BASE_IMAGE` 미설정 머신(Mac mini 등)은 영향 없음

## v1.7.0 (2026-05-06)

### Added
- Multi-host 머신별 분기 지원 — Mac mini와 Ubuntu 데스크탑에서 동일 vscode-tunnel 리포를 git 충돌 없이 운영
  - `BASE_IMAGE` 환경변수: Dockerfile 최상단에 `ARG BASE_IMAGE=ubuntu:24.04` 도입, `docker-compose.yml`의 `build.args`로 주입. 머신별 `.env`로만 분기되므로 Dockerfile은 commit된 한 벌만 유지
  - `DATASETS_PATH` 환경변수 + `docker-compose.local.yml`(gitignored) 패턴: 머신별 데이터셋 마운트를 `.env`로 분기. 컨테이너 내부 경로는 `/datasets`로 고정해 코드의 절대경로 참조가 양쪽 머신에서 일관됨
- Multi-host Study Timer 사이드카 (nanobot-docker 리포의 `multi-host-plan.md` Phase 1 연계)
  - `docker-compose.tailscale.yml` 신규: nginx alpine으로 기존 `study-timer-data` named volume을 read-only HTTP(`:8765`)로 노출. `external: true`로 메인 stack 볼륨 재사용
  - `study-timer-nginx.conf` 신규: `autoindex on; autoindex_format json;` + `Cache-Control: no-cache`로 nanobot의 list 도구가 단일 GET으로 날짜 인덱스 획득
  - `TAILSCALE_IP` 환경변수로 포트 바인딩(`${TAILSCALE_IP}:8765:80`) → Tailnet 인터페이스에만 노출, LAN/외부 차단
- `start.sh` 자동 감지 확장 (누적 `-f` 방식, POSIX sh 유지)
  - GPU 감지 → `docker-compose.gpu.yml` (기존 동작 보존)
  - `docker-compose.local.yml` 존재 시 자동 적용
  - `.env`의 활성 `TAILSCALE_IP=` 라인 감지 시 `docker-compose.tailscale.yml` 자동 적용
  - 각 단계는 표준 메시지로 보고 (`"GPU detected: ..."` / `"Local override detected: ..."` / `"Tailscale sidecar detected: ..."`)
- `UBUNTU_SETUP.md`에 3-5 (Study Timer 사이드카 활성화 절차) 신규 섹션 추가

### Changed
- `Dockerfile`: Stage 2의 `FROM ubuntu:24.04` → `FROM ${BASE_IMAGE}` (기본값 동일)
- `docker-compose.yml`: `build: .` → `build.args.BASE_IMAGE: ${BASE_IMAGE:-ubuntu:24.04}` 형태로 변경
- `.env.sample`: `BASE_IMAGE` / `DATASETS_PATH` / `TAILSCALE_IP` 안내 주석 추가 (모두 코멘트 처리, 미설정 시 기존 동작)
- `.gitignore`: `docker-compose.local.yml` 무시 항목 추가
- `README.md` 전면 개편: 환경변수 표, start.sh 자동 감지 표, 머신별 오버라이드 패턴 섹션, 파일 구성에 신규 파일 반영
- `UBUNTU_SETUP.md` 재작성: 사전 조건 단축(docker compose v2 / docker 그룹 / NTP), 3-3을 `.env`의 `BASE_IMAGE` 한 줄 방식으로, 3-4를 `docker-compose.local.yml` + `${DATASETS_PATH}` 패턴으로 재서술, 운영 팁에 사이드카 절차 통합

### Removed
- `~/.codex` 호스트 마운트 제거 (사용자가 OpenAI Codex CLI 미사용). 호스트 `~/.codex` 디렉토리는 그대로 보존되며, 향후 필요 시 `docker-compose.yml`에 라인 한 줄 복원으로 즉시 재마운트 가능

### Design notes
- 머신별 사이드카 분기를 compose `profiles:` 대신 별도 commit 파일(`docker-compose.tailscale.yml`)로 분리한 이유: profile 비활성 상태에서도 변수 치환이 평가되어 Mac에서 `${TAILSCALE_IP}:8765:80` 빈 IP 검증 이슈가 발생할 수 있음. `start.sh`가 `-f`로 얹는 방식이면 Mac은 파일을 아예 로드하지 않아 치환 시도 자체가 일어나지 않음. 기존 `docker-compose.gpu.yml`과 동일 패턴
- Ubuntu 권장 베이스 이미지를 `nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04`로 정했음. PyTorch 2.5/2.6 공식 wheel + cuDNN 9 + Mac 기본 OS와 동일한 ubuntu 24.04 → 한 Dockerfile이 양쪽에서 동일하게 빌드. Phase 4의 mmcv-full은 사전 빌드 wheel 부재 시 source build 가능 (devel)

### Migration
- **기존 Mac mini**: `.env` 변경 불필요. 모든 신규 변수가 선택이며 미설정 시 `ubuntu:24.04` + 단일 docker-compose.yml로 기존 동작 그대로
- **Ubuntu 신규 셋업**: `UBUNTU_SETUP.md` 참조. `.env`에 `BASE_IMAGE=nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04` + 필요 시 `DATASETS_PATH=/data/datasets` + (사이드카 활성화 시) `TAILSCALE_IP=<tailscale ip -4 결과>` 추가
- nanobot-docker 리포의 `multi-host-plan.md` Phase 2 (custom-tools.js 다중 source 머지)는 별도 리포 작업으로 분리

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
