# vscode-tunnel

어디서든 VS Code로 원격 접속할 수 있는 Docker 기반 개발 환경입니다.
Mac(Apple Silicon)과 Ubuntu(x86_64) 모두 별도 수정 없이 동작합니다.

---

## 포함 구성

| 구성 요소 | 버전 / 내용 |
|-----------|------------|
| Base Image | Ubuntu 24.04 (기본값, `.env`의 `BASE_IMAGE`로 CUDA 이미지 등으로 오버라이드 가능) |
| OpenCV | 4.10.0 (소스 빌드, contrib 포함) |
| VS Code CLI | stable / 빌드 시 호스트 아키텍처 자동 감지 (arm64, x64) / 매 컨테이너 시작 시 최신 stable 로 자동 갱신 (v1.9.0+) |
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
# 아래는 모두 선택 (미설정 시 기존 동작 그대로):
# BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04   # CUDA 학습 환경
# DATASETS_PATH=/data/datasets                            # docker-compose.local.yml과 함께 사용
# TAILSCALE_IP=100.x.y.z                                  # multi-host study-timer 사이드카 활성화
```

| 변수 | 기본값 | 설명 |
|------|-------|------|
| `TUNNEL_NAME` | (필수) | VS Code tunnel 이름. 전 세계 고유해야 함 |
| `WORKSPACE_PATH` | `./workspace` | 컨테이너의 `/workspace`에 마운트할 호스트 경로 |
| `TZ` | `Asia/Seoul` | 컨테이너 timezone (study-timer 날짜 경계용) |
| `BASE_IMAGE` | `ubuntu:24.04` | 빌드 베이스 이미지. CUDA 사용 시 `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04` 권장 |
| `DATASETS_PATH` | (미설정) | 데이터셋 호스트 경로. `docker-compose.local.yml`과 함께 사용 |
| `TAILSCALE_IP` | (미설정) | Tailscale IP. 설정 시 `study-timer-http` 사이드카(`:8765`) 자동 동반 기동 |

> `.env` 파일은 `.gitignore`에 등록되어 있어 Git에 커밋되지 않습니다.

### 2. 컨테이너 빌드 및 실행

```bash
./start.sh
```

`start.sh`가 환경을 자동 감지해 다음 compose 파일을 누적 적용합니다.

| 감지 조건 | 추가 적용 |
|----------|----------|
| (기본) | `-f docker-compose.yml` |
| `nvidia-smi` 동작 | `-f docker-compose.gpu.yml` (GPU 활성화) |
| `/dev/video0` 존재 | `-f docker-compose.camera.yml` (ELP 스테레오 카메라 패스스루) |
| `docker-compose.local.yml` 존재 | `-f docker-compose.local.yml` (머신별 오버라이드, gitignored) |
| `.env`의 활성 `TAILSCALE_IP=` 라인 | `-f docker-compose.tailscale.yml` (study-timer 사이드카) |

Mac에서 `BASE_IMAGE`/`TAILSCALE_IP`/local 파일을 모두 미설정 시 기존 동작
(ubuntu:24.04 + 단일 docker-compose.yml)과 완전히 동일합니다.

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
  - ~/.ssh:/root/.ssh-host:ro                # SSH 키 (entrypoint가 /root/.ssh로 복사하며 권한 보정)
  - vscode-cli-data:/root/.vscode/cli        # tunnel 인증 상태 유지
  - vscode-server-data:/root/.vscode-server  # VS Code 서버/익스텐션 데이터 유지
  - ~/.claude:/root/.claude                  # Claude Code 인증 공유
  - study-timer-data:/root/.study-timer      # Study Timer 일별 JSON 저장소
```

> Timezone은 Dockerfile에서 `Asia/Seoul`로 영구 고정됩니다 (`.env`의 `TZ`로
> 오버라이드 가능). 이전에 사용하던 `/etc/localtime`/`/etc/timezone` bind mount는
> 호스트/컨테이너 측 심볼릭 링크 dereference 차이로 의도와 다르게 동작하여
> v1.7.6에서 제거했습니다.

> `/dev/shm` 은 v1.11.1 부터 `shm_size: 8gb` 로 상향됐습니다 (Docker 기본 64MB).
> PyTorch DataLoader 멀티워커 (`num_workers > 0`) 에서 공유 메모리 부족으로
> `Bus error` 가 나는 문제를 회피하기 위함이며, 호스트 RAM 을 선점하지 않고
> 사용량만큼만 점유합니다.

---

## GPU 지원

NVIDIA GPU가 있는 Ubuntu 환경에서는 `start.sh`가 자동으로 GPU를 활성화합니다.

사전 조건:
- 호스트에 NVIDIA 드라이버 설치
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) 설치

컨테이너 안에서 CUDA 라이브러리(cuDNN 등)가 필요한 경우, **Dockerfile은 손대지
않고 `.env`의 `BASE_IMAGE` 한 줄로 베이스 이미지를 분기**합니다.

```env
# Phase 3/4 학습 권장 (PyTorch 2.5+ / cuDNN / mmcv-full source build 가능)
BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04
```

| 용도 | 권장 이미지 |
|------|-----------|
| 학습/추론 (Phase 3/4) | `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04` |
| 추론 전용 | `nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04` |

Mac은 미설정 → 기본값 `ubuntu:24.04`로 빌드되어 영향 없음.

---

## USB 카메라 (ELP 스테레오)

ELP USB 스테레오 카메라(UVC)가 연결된 호스트에서는 `start.sh` / `reload.sh`가
`/dev/video0` 존재를 감지해 `docker-compose.camera.yml`을 자동 적용하고, 카메라
노드를 컨테이너에 패스스루합니다.

```yaml
# docker-compose.camera.yml
services:
  vscode-tunnel:
    devices:
      - /dev/video0:/dev/video0
      - /dev/video1:/dev/video1
    group_add:
      - video
```

**적용 전 노드 확인**: 스테레오 카메라는 좌/우 센서가 각각 video4linux 노드로
잡히며, 노드 번호는 호스트 하드웨어/연결 순서에 따라 달라질 수 있습니다. 호스트에서
실제 노드를 먼저 확인하세요.

```bash
# 카메라 노드 목록
v4l2-ctl --list-devices

# 특정 노드의 지원 포맷/해상도
v4l2-ctl -d /dev/video0 --list-formats-ext
```

노드가 `/dev/video0` / `/dev/video1`과 다르면 `docker-compose.camera.yml`의
`devices` 항목을 실제 노드로 맞춥니다. 존재하지 않는 노드를 매핑하면 컨테이너
기동이 실패합니다.

**적용 / 확인**:

```bash
# 재생성 (devices 는 컨테이너 생성 시점에만 반영, restart 로는 적용 안 됨)
./reload.sh

# 컨테이너 내부에서 노드 인식 확인
docker exec vscode-tunnel ls -l /dev/video*
```

> 카메라가 없는 호스트(Mac 등)에서는 `/dev/video0` 미존재로 오버레이가 적용되지
> 않아 기존 동작과 동일합니다. 컨테이너 안에서 OpenCV 등으로 영상을 다루는 데
> 필요한 추가 패키지는 `Dockerfile` 영역이라 이 오버라이드 범위 밖입니다.

---

## 머신별 오버라이드 패턴

머신별 차이(데이터셋 경로, multi-host 사이드카 등)를 git 충돌 없이 흡수하기 위한
세 축 분기.

| 축 | 파일 / 변수 | git 상태 | 활성화 조건 |
|----|------------|---------|----------|
| 베이스 이미지 | `.env`의 `BASE_IMAGE` | gitignored | `.env`에 값 설정 |
| GPU | `docker-compose.gpu.yml` | commit | `nvidia-smi` 동작 |
| USB 카메라 | `docker-compose.camera.yml` | commit | `/dev/video0` 존재 |
| 머신별 마운트 | `docker-compose.local.yml` | gitignored | 파일 존재 |
| Multi-host 사이드카 | `docker-compose.tailscale.yml` + `.env`의 `TAILSCALE_IP` | commit (파일) / gitignored (값) | `.env`에 `TAILSCALE_IP` 설정 |

Ubuntu 학습 호스트의 전형적 셋업 절차는 [UBUNTU_SETUP.md](UBUNTU_SETUP.md) 참조.
Multi-host study-timer 통합 설계는 nanobot-docker 리포의 `multi-host-plan.md` 참조.

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

# 재시작 (in-place, 이미지 재빌드 포함, 변경된 컨테이너만 recreate)
./start.sh

# 안전 재기동 (down 후 up, 이미지 재빌드 포함, 좀비 네트워크/사이드카까지 정리)
./reload.sh
```

두 스크립트의 차이는 `docker compose down`을 먼저 거치는지 여부입니다. `start.sh`는
in-place 갱신이라 변경된 컨테이너만 recreate되어 빠르지만, 옛 docker network ID를
들고 있는 좀비 사이드카 같은 정합성 문제는 자동 정리되지 않습니다. `reload.sh`는
같은 `COMPOSE_ARGS`(모든 compose 오버레이)로 `down` 후 `up -d --build`를 실행하여
전체 컨테이너/네트워크를 깨끗하게 갈아엎으므로 정합성까지 회복합니다. named volume에
저장된 데이터는 양쪽 모두 보존됩니다.

`reload.sh`는 v1.9.0 부터 마지막 단계에서 entrypoint 로그를 자동으로 추려 출력합니다.
`Dockerfile` / `entrypoint.sh` / `extensions/` 등 이미지에 burn-in 되는 자산을 수정한
뒤에도 `./reload.sh` 한 번으로 down -> build -> up -> 검증까지 끝납니다.

```
Verifying entrypoint output...
[entrypoint] vscode CLI refreshed: code 1.122.0 (commit 6a49527...)
[entrypoint] SSH 키 복사 및 권한 보정 완료
[entrypoint] study-timer extension 배치 및 등록 완료

Container status:
NAMES           STATUS
vscode-tunnel   Up 8 seconds (healthy)
```

**언제 어느 쪽을 쓰나:**

| 변경 유형 | 권장 스크립트 |
|---|---|
| `.env` 만 변경 (TUNNEL_NAME 등) | `docker compose down && ./start.sh` |
| `docker-compose*.yml` 만 변경 | `./start.sh` (in-place recreate) |
| `Dockerfile` / `entrypoint.sh` / extension 소스 변경 | **`./reload.sh`** (down + build + 검증) |
| 좀비 사이드카 / 네트워크 정합성 복구 | **`./reload.sh`** |

---

## Study Timer

특정 워크스페이스에서의 실사용 시간을 자동 측정하여 일별 JSON 파일로 저장하는 내장 VS Code extension입니다.

### 대상 워크스페이스
- 컨테이너 내부 경로: `/workspace/study/physical-ai-study`
- 이 경로가 최상위 폴더인 VS Code 창에서만 활성화됩니다.

### 측정 규칙
- **Active 조건**: 창 focus 상태 + 최근 idle 임계 내 활동(편집 / 커서 이동 / 에디터 전환 / focus 복귀)
- **idle 임계**: 활성 탭이 markdown preview(미리 보기) 이면 20분, 그 외 모든 탭(텍스트 에디터 / 노트북 / 기타 webview) 은 5분 (v1.10.1+). 미리 보기는 webview 내부 활동 신호가 API 로 노출되지 않아 동일 임계 적용이 부당하다는 점을 보정 — 자리 비움 시 최대 20분까지 시간이 부풀려질 수 있음
- 1초 단위로 `active_seconds` 누적, 30초 주기로 파일에 atomic write
- idle로는 세션이 끊기지 않고 카운트만 중단되므로, PC를 옮기거나 자리를 비워도 자연스럽게 측정 중단됩니다.
- 자정을 넘기면 세션을 두 파일로 분할 기록합니다.
- 각 extension 활성화(activate)는 자기만의 `instance_id`로 표시된 세션을 새로 추가하며, flush 시 자기 세션의 `active_seconds`/`end`만 갱신합니다. 같은 워크스페이스를 두 VS Code 창에서 열어도 각 창이 독립된 세션을 가지므로 충돌 없이 합산됩니다. reload로 0초짜리 세션이 남는 경우 `deactivate` 시 정리합니다.

### Phase/Week 집계 (`by_phase_week`)
- 1초 tick마다 현재 활성 에디터(텍스트 또는 노트북)의 파일 경로를 확인해 카테고리별 누적 초를 함께 기록합니다.
- 카테고리 키 규칙
  - `Studies/Phase N/weekM/...` 하위 파일 -> `"Phase N/weekM"`
  - `Studies/Hardware-Arm/stageN/...` 하위 파일 -> `"Hardware-Arm/stageN"`
  - 그 외(Roadmap, README, Hardware-Arm 최상위 문서, 활성 에디터 없음 등) -> `"other"`
- 활성 탭이 markdown preview(미리 보기) 인 경우에도 원본 `.md` 파일의 카테고리로 귀속됩니다 (v1.10.0+). 가장 최근에 활성화되었던 `.md` 경로를 추적해 미리 보기 탭 라벨의 파일명과 basename 으로 검증한 뒤 매칭합니다. 미리 보기 탭의 idle 임계는 20분으로 확장되어 (v1.10.1+) 장문 markdown 읽기 세션이 5분 임계로 끊기지 않도록 합니다.
- 불변식: `active_seconds == sum(by_phase_week.values())`
- nanobot/MCP 쪽에서는 `other`를 집계에서 제외하고 `Phase N/weekM` / `Hardware-Arm/stageN` 키만 사용하는 것을 권장합니다.

### "other" 카테고리 상세 (`other_breakdown`, v1.11.0+)
- `by_phase_week.other` 가 단일 합산값이라 "그 시간에 뭘 봤는지" 추적이 불가능했던 한계를 보완합니다.
- 키 포맷
  - 워크스페이스 내부 파일: workspace-relative POSIX 경로 (예: `Studies/Roadmap.md`)
  - 워크스페이스 외부 파일: absolute path 그대로
  - 활성 에디터 없음: `(no active editor)` sentinel
  - 구버전 마이그레이션: `(legacy unattributed)` sentinel (실제 내역 복구 불가)
- 불변식: `sum(other_breakdown.values()) == by_phase_week.other`. 매 `other` tick 에서 `by_phase_week.other` 와 `other_breakdown` 키가 같은 if 블록 안에서 함께 +1
- 사용 예: nanobot MCP 측 신규 도구 `get-study-other-breakdown` 으로 명시적 요청 시에만 노출. 기존 도구 (`get-today` / `get-date` / `get-study-phase-week` 등) 의 응답 형식은 변경 없음

### 저장 경로 / 포맷
- 경로: `/root/.study-timer/YYYY-MM-DD.json` (docker named volume `study-timer-data`)
- 컨테이너 timezone(`Asia/Seoul`, Dockerfile에서 고정)을 사용하므로 모든 타임스탬프와 날짜 경계는 로컬 TZ 기준입니다.

```json
{
  "date": "2026-04-14",
  "workspace": "physical-ai-study",
  "active_seconds": 5400,
  "by_phase_week": {
    "Phase 1/week2": 3000,
    "Phase 2/week1": 1000,
    "Hardware-Arm/stage1": 1000,
    "other": 400
  },
  "other_breakdown": {
    "Studies/Roadmap.md": 250,
    "README.md": 100,
    "(no active editor)": 50
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

### Multi-host HTTP 노출 (`study-timer-http` 사이드카)

`.env`에 `TAILSCALE_IP`가 설정된 호스트에서는 `study-timer-http` 사이드카가 자동
기동되어 `http://${TAILSCALE_IP}:8765/`로 `study-timer-data` 볼륨의
`YYYY-MM-DD.json` 파일을 nginx autoindex(JSON)로 노출합니다.

| 항목 | 내용 |
|------|------|
| 노출 IP | `${TAILSCALE_IP}` (Tailnet 인터페이스에만 바인딩, LAN/외부 차단) |
| 포트 | `8765` → 컨테이너 `:80` |
| 응답 | `study-timer-data` 볼륨의 `YYYY-MM-DD.json` 파일 (read-only) |
| 헬스체크 | `wget http://127.0.0.1/` 1분 주기 (IPv4 명시) |

> 헬스체크가 `localhost` 대신 `127.0.0.1`을 쓰는 이유: nginx alpine은 read-only
> bind-mount된 `default.conf` 때문에 IPv6 listener를 추가하지 못해 IPv4-only로
> listen 합니다. busybox wget이 `localhost`를 IPv6(`::1`)로 먼저 시도하면 fallback
> 없이 실패하여 false `unhealthy`가 발생합니다 (v1.7.5 fix).

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

## VS Code CLI 자동 갱신

이미지에 burn-in 된 `code` 바이너리는 빌드 시점에 고정되어 시간이 지날수록 클라이언트
(vscode.dev / VS Code Desktop) 와 격차가 누적될 수 있습니다. v1.9.0 부터 `entrypoint.sh`
의 `refresh_vscode_cli()` 가 매 컨테이너 시작 시 stable 채널의 최신 CLI 를 받아
`/usr/local/bin/code` 를 덮어씁니다.

| 항목 | 동작 |
|---|---|
| 갱신 시점 | 컨테이너 시작 시 (tunnel 기동 직전) |
| 다운로드 URL | `https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-${ARCH}` |
| 타임아웃 | `curl --max-time 30` (네트워크 hang 차단) |
| 백업 | 직전 CLI 를 `/usr/local/bin/code.prev` 로 보존 |
| 실패 fallback | 다운로드/추출 실패 시 이미지 burn-in 본 CLI 를 그대로 사용 |

**호환성**: VS Code tunnel 은 클라이언트가 요청한 commit hash 의 server 를 CLI 가
다운로드/실행하는 구조이므로 **CLI 가 클라이언트보다 같거나 더 최신** 이면 일반적으로
호환됩니다. 옛 클라이언트로 접속해도 해당 commit 의 server 가 별도로 받아져
`/root/.vscode/cli/servers/Stable-<hash>/` 에 누적되므로 문제 없습니다.

**문제 발생 시 롤백**:

```bash
docker exec vscode-tunnel mv /usr/local/bin/code.prev /usr/local/bin/code
docker exec vscode-tunnel code tunnel restart
```

최후 수단으로 `docker compose up -d --force-recreate` 시 entrypoint 가 다시 최신
다운로드를 시도하며, 그것도 실패하면 이미지 burn-in CLI 로 fallback.

---

## 파일 구성

```
.
├── Dockerfile                    # 이미지 정의 (multi-stage: extension builder + ${BASE_IMAGE} 런타임)
├── docker-compose.yml            # 컨테이너 실행 설정 (build args에 BASE_IMAGE 주입)
├── docker-compose.gpu.yml        # NVIDIA GPU 오버라이드 (start.sh 자동 적용)
├── docker-compose.camera.yml     # ELP USB 스테레오 카메라 패스스루 (/dev/video0 시 자동 적용)
├── docker-compose.tailscale.yml  # study-timer-http 사이드카 (TAILSCALE_IP 시 자동 적용)
├── docker-compose.local.yml      # 머신별 마운트 등 로컬 오버라이드 (gitignored)
├── study-timer-nginx.conf        # 사이드카 nginx 설정 (autoindex JSON, no-cache)
├── start.sh                      # GPU/local/tailscale 자동 감지 시작 스크립트 (in-place recreate)
├── reload.sh                     # 안전 재기동: down -> build -> up -> entrypoint 검증 출력
├── entrypoint.sh                 # 터널 watchdog + VS Code CLI 자동 갱신 + Study Timer extension 배치
├── extensions/
│   └── study-timer/              # 실사용 시간 측정 VS Code extension (TypeScript)
├── UBUNTU_SETUP.md               # Ubuntu 학습 호스트 독립 배포 가이드
├── .env                          # 환경 변수 - Git 미포함
├── .env.sample                   # 환경 변수 템플릿 - Git 포함
├── .gitignore                    # .env, workspace/, docker-compose.local.yml 등 제외
└── workspace/                    # 컨테이너에 마운트되는 작업 디렉토리 - Git 미포함
```
