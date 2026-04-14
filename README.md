# vscode-tunnel

어디서든 VS Code로 원격 접속할 수 있는 Docker 기반 개발 환경입니다.
Mac(Apple Silicon)과 Ubuntu(x86_64) 모두 별도 수정 없이 동작합니다.

---

## 포함 구성

| 구성 요소 | 버전 / 내용 |
|-----------|------------|
| Base Image | Ubuntu 24.04 |
| OpenCV | 4.10.0 (소스 빌드, contrib 포함) |
| VS Code CLI | stable / 빌드 시 호스트 아키텍처 자동 감지 (arm64, x64) |
| Claude Code | 최신 버전 (native installer) |
| 빌드 도구 | CMake, Ninja, GDB, build-essential |

---

## 빠른 시작

### 1. 환경 변수 파일 설정

`.env.sample`을 복사하여 `.env` 파일을 만들고, 값을 설정합니다.

```bash
cp .env.sample .env
```

```env
TUNNEL_NAME=my-dev-tunnel       # 소문자, 숫자, 하이픈만 사용 가능 (전 세계 고유해야 함)
WORKSPACE_PATH=./workspace      # 컨테이너에 마운트할 작업 디렉토리 경로
```

> `.env` 파일은 `.gitignore`에 등록되어 있어 Git에 커밋되지 않습니다.

### 2. 컨테이너 빌드 및 실행

```bash
./start.sh
```

`start.sh`가 NVIDIA GPU 존재 여부를 자동 감지하여 적절한 설정으로 컨테이너를 시작합니다.

| 환경 | 동작 |
|------|------|
| Mac / GPU 없는 Linux | `docker-compose.yml`만 사용 |
| Ubuntu + NVIDIA GPU | `docker-compose.gpu.yml` 오버레이 자동 적용 |

### 3. VS Code tunnel 인증

컨테이너 최초 실행 시 GitHub 인증이 필요합니다.

```bash
docker compose logs -f
```

로그에 출력되는 URL과 코드를 브라우저에서 입력해 GitHub 계정으로 인증합니다.
인증 정보는 `vscode-cli-data` 볼륨(`/root/.vscode/cli`)에 저장되므로 이후 재시작 시 재인증 불필요합니다.

### 4. 외부에서 접속

- **브라우저**: `https://vscode.dev/tunnel/<TUNNEL_NAME>`
- **VS Code Desktop**: `Remote - Tunnels` 익스텐션에서 터널 이름 선택

---

## 볼륨 구성

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace             # 작업 디렉토리 (.env에서 경로 설정)
  - ~/.gitconfig:/root/.gitconfig:ro         # 호스트 git 설정 공유
  - ~/.ssh:/root/.ssh:ro                     # SSH 키 공유 (git push 등)
  - vscode-cli-data:/root/.vscode/cli        # tunnel 인증 상태 유지
  - vscode-server-data:/root/.vscode-server  # VS Code 서버/익스텐션 데이터 유지
  - ~/.claude:/root/.claude                  # Claude Code 인증 공유
  - ~/.codex:/root/.codex                    # Codex 인증 공유
  - study-timer-data:/root/.study-timer      # Study Timer 일별 JSON 저장소
  - /etc/localtime:/etc/localtime:ro         # 호스트 timezone 상속
  - /etc/timezone:/etc/timezone:ro
```

---

## GPU 지원

NVIDIA GPU가 있는 Ubuntu 환경에서는 `start.sh`가 자동으로 GPU를 활성화합니다.

사전 조건:
- 호스트에 NVIDIA 드라이버 설치
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) 설치

컨테이너 안에서 CUDA 라이브러리(cuDNN 등)가 필요한 경우, Dockerfile의 베이스 이미지를 변경해야 합니다:

| 용도 | 베이스 이미지 |
|------|-------------|
| 런타임만 (추론 등) | `nvidia/cuda:12.x-runtime-ubuntu24.04` |
| 빌드도 필요 (컴파일) | `nvidia/cuda:12.x-devel-ubuntu24.04` |

---

## 터널 이름 변경

`.env` 파일의 `TUNNEL_NAME`을 수정하고 컨테이너를 재시작합니다.

```bash
docker compose down
./start.sh
```

> 터널 이름은 소문자, 숫자, 하이픈만 허용되며 전 세계적으로 고유해야 합니다.

---

## 컨테이너 중지 / 재시작

```bash
# 중지
docker compose down

# 재시작 (재빌드 없이)
./start.sh
```

---

## Study Timer

특정 워크스페이스에서의 실사용 시간을 자동 측정하여 일별 JSON 파일로 저장하는 내장 VS Code extension입니다.

### 대상 워크스페이스
- 컨테이너 내부 경로: `/workspace/study/visual-slam-and-perception-learning`
- 이 경로가 최상위 폴더인 VS Code 창에서만 활성화됩니다.

### 측정 규칙
- **Active 조건**: 창 focus 상태 + 최근 5분 이내 활동(편집 / 커서 이동 / 에디터 전환 / focus 복귀)
- 1초 단위로 `active_seconds` 누적, 30초 주기로 파일에 atomic write
- idle로는 세션이 끊기지 않고 카운트만 중단되므로, PC를 옮기거나 자리를 비워도 자연스럽게 측정 중단됩니다.
- 자정을 넘기면 세션을 두 파일로 분할 기록합니다.
- VS Code reload 등으로 extension이 재활성화될 때 같은 날 마지막 세션의 `end`가 5분 이내면 그 세션을 이어받습니다 (세션 중복 방지).

### Phase/Week 집계 (`by_phase_week`)
- 1초 tick마다 현재 활성 에디터(텍스트 또는 노트북)의 파일 경로를 확인해 카테고리별 누적 초를 함께 기록합니다.
- 카테고리 키 규칙
  - `Studies/Phase N/weekM/...` 하위 파일 -> `"Phase N/weekM"`
  - 그 외(Roadmap, README, 활성 에디터 없음 등) -> `"other"`
- 불변식: `active_seconds == sum(by_phase_week.values())`
- nanobot/MCP 쪽에서는 `other`를 집계에서 제외하고 `Phase N/weekM` 키만 사용하는 것을 권장합니다.

### 저장 경로 / 포맷
- 경로: `/root/.study-timer/YYYY-MM-DD.json` (docker named volume `study-timer-data`)
- 호스트 timezone을 상속하므로 모든 타임스탬프와 날짜 경계는 로컬 TZ 기준입니다.

```json
{
  "date": "2026-04-14",
  "workspace": "visual-slam-and-perception-learning",
  "active_seconds": 5400,
  "by_phase_week": {
    "Phase 1/week2": 3000,
    "Phase 2/week1": 2000,
    "other": 400
  },
  "sessions": [
    {
      "start": "2026-04-14T09:00:00+09:00",
      "end": "2026-04-14T10:30:00+09:00",
      "active_seconds": 5400
    }
  ],
  "last_updated": "2026-04-14T10:30:15+09:00"
}
```

### 외부 컨테이너에서 공유 (예: nanobot-docker)

`study-timer-data` named volume을 `external: true`로 참조하면 다른 compose 프로젝트에서 읽어갈 수 있습니다.

```yaml
services:
  my-service:
    volumes:
      - study-timer-data:/data/study-timer:ro
volumes:
  study-timer-data:
    external: true
```

vscode-tunnel 컨테이너를 먼저 기동해 볼륨이 생성된 이후에 nanobot compose를 올리면 됩니다.

---

## 자동 복구 (Watchdog)

`entrypoint.sh`가 watchdog으로 동작하며, 120초마다 터널 상태를 감시합니다.

| 검사 항목 | 설명 |
|-----------|------|
| 프로세스 생존 | 터널 프로세스가 살아있는지 확인 |
| 프로세스 중복 | `code tunnel` 프로세스가 2개 이상이면 비정상 |
| 터널 상태 | `code tunnel status`의 상태가 `Connected`인지 확인 |

- 비정상 감지 시 터널을 자동 재시작합니다.
- 3회 연속 복구 실패 시 컨테이너를 종료하고, Docker의 `restart: unless-stopped` 정책으로 컨테이너 자체가 재시작됩니다.
- 초기 시작 후 5분간은 grace period를 적용하여 GitHub 인증 대기 중 오탐을 방지합니다.

---

## 파일 구성

```
.
├── Dockerfile              # 이미지 정의 (multi-stage: extension builder + Ubuntu 24.04 런타임)
├── docker-compose.yml      # 컨테이너 실행 설정
├── docker-compose.gpu.yml  # NVIDIA GPU 오버라이드 설정
├── start.sh                # GPU 자동 감지 시작 스크립트
├── entrypoint.sh           # 터널 watchdog + Study Timer extension 배치 스크립트
├── extensions/
│   └── study-timer/        # 실사용 시간 측정 VS Code extension (TypeScript)
├── .env                    # 환경 변수 (TUNNEL_NAME 등) - Git 미포함
├── .env.sample             # 환경 변수 템플릿 - Git 포함
├── .gitignore              # .env, workspace/, .DS_Store 등 제외
└── workspace/              # 컨테이너에 마운트되는 작업 디렉토리 - Git 미포함
```
