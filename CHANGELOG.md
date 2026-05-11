# Changelog

## v1.7.6 (2026-05-12)

### Fixed
- 컨테이너 timezone 설정이 어긋나 `code tunnel` CLI 등 일부 컴포넌트가 UTC로
  동작하던 문제 수정
  - 증상: `TZ=Asia/Seoul` 환경변수와 `date` 출력은 KST 정상이지만, `code tunnel`
    CLI의 stdout 로그 timestamp(`[2026-05-11 15:19:50]` 형태)가 UTC로 찍히고
    `/etc/localtime`이 `/usr/share/zoneinfo/Etc/UTC`를 가리키는 심볼릭 링크로
    남아있음
  - 원인: `ubuntu:24.04` 베이스 이미지의 기본 `/etc/localtime`이 `Etc/UTC`를
    가리키는 상태 그대로였고, docker-compose의
    `/etc/localtime:/etc/localtime:ro` bind mount가 호스트 측 심볼릭 링크와
    컨테이너 측 심볼릭 링크를 모두 dereference하면서 호스트 KST 데이터가
    컨테이너의 `/usr/share/zoneinfo/Etc/UTC` 위에 마운트되는 의도치 않은 동작
    발생. 결과적으로 `iana-time-zone` 기반 도구가 `/etc/localtime` 심볼릭 링크
    이름("Etc/UTC")을 IANA tz 이름으로 추출 → UTC로 동작

### Changed
- `Dockerfile`: 이미지 빌드 시점에 `tzdata` 설치 + `/etc/localtime` 심볼릭 링크를
  `Asia/Seoul`로 영구 고정 + `dpkg-reconfigure -f noninteractive tzdata` 적용.
  `ARG TZ=Asia/Seoul`로 빌드 시 다른 timezone으로 오버라이드 가능. 캐시
  무효화 영향 최소화를 위해 OpenCV 빌드 이후 단계에 배치
- `docker-compose.yml`: 잘못 동작하던 `/etc/localtime`/`/etc/timezone` bind
  mount 두 줄 제거. timezone은 이제 이미지에 내장되어 마운트 불필요
- `docker-compose.yml`: `TZ` 환경변수 주석을 새 동작에 맞게 정리
  (Node 등 TZ 환경변수를 따르는 프로세스용이며 `/etc/localtime`과 일치)
- `README.md`: 볼륨 구성 표에서 timezone 마운트 라인 제거. Study Timer
  섹션의 "호스트 timezone 상속" 문구를 "Dockerfile에서 고정"으로 정정

### Notes
- `code tunnel` CLI 바이너리(Microsoft, Rust)는 timestamp를 **UTC로
  hardcoded**하여 출력한다. `/etc/localtime`/`TZ`와 무관하게 UTC로 찍히며
  외부에서 변경 불가. 따라서 `docker compose logs vscode-tunnel`에 표시되는
  CLI 로그의 timestamp는 v1.7.6 이후에도 여전히 UTC. KST로 환산하려면
  +9시간 가산 필요
- CLI 로그를 제외한 다른 모든 컴포넌트(`date`, Python, Node, vscode-server의
  로그 디렉토리명 `YYYYMMDDTHHMMSS`, study-timer 익스텐션의 일별 JSON 등)는
  KST로 정상 동작함을 v1.7.6 적용 후 검증

### Migration
- 모든 사용자: 컨테이너 재빌드와 재기동이 필요
  ```bash
  git pull
  docker compose build
  ./start.sh
  ```
  - OpenCV 빌드 이후 단계 변경이라 캐시가 살아남아 재빌드는 빠르게 끝남
  - 컨테이너 재생성 후 GitHub tunnel device flow 재인증이 요구될 수 있음
    (`docker compose logs -f`에 표시되는 코드로 진행)
- 검증: `docker exec vscode-tunnel ls -la /etc/localtime`이
  `/usr/share/zoneinfo/Asia/Seoul`을 가리키는지 확인

## v1.7.5 (2026-05-08)

### Fixed
- `study-timer-http` 사이드카가 정상 동작 중에도 Docker가 `unhealthy`로 표시하던
  헬스체크 false-negative 수정
  - 증상: `docker ps`에서 `Up X minutes (unhealthy)`. 실제로는 `${TAILSCALE_IP}:8765/`
    HTTP 200 OK 응답 정상
  - 원인: 헬스체크가 `wget http://localhost/`를 사용. 컨테이너 `/etc/hosts`에
    `localhost`가 IPv4(`127.0.0.1`)와 IPv6(`::1`) 양쪽으로 매핑되어 있어 busybox
    wget이 IPv6 먼저 시도. nginx alpine 이미지의 entrypoint가 read-only로
    bind-mount된 `default.conf`에 IPv6 listener를 추가하지 못해 IPv4-only로
    listen → `::1:80`에서 connection refused. busybox wget은 IPv4 fallback 없이
    종료하여 retries 한도(3회)까지 모두 실패
  - 결과: 사이드카 본체는 정상이지만 healthcheck 가시성을 신뢰할 수 없어
    모니터링/오케스트레이션 도구가 잘못된 판단(예: 자동 재시작)을 할 수 있음

### Changed
- `docker-compose.tailscale.yml`: 헬스체크 URL을 `http://localhost/` →
  `http://127.0.0.1/`로 교체. nginx의 IPv4 listener와 정합되어 사이드카가
  `healthy`로 정상 표기됨. 동작 자체는 v1.7.4와 동일

### Migration
- TAILSCALE_IP 사이드카 사용자:
  ```bash
  git pull
  ./start.sh   # study-timer-http 컨테이너만 recreate 됨
  ```
  `docker ps` 출력에서 `study-timer-http` 가 `Up X seconds (healthy)` 로
  표시되는지 확인
- 비사용자(`.env`에 `TAILSCALE_IP` 미설정): 영향 없음

## v1.7.4 (2026-05-08)

### Fixed
- Linux 호스트(Ubuntu 등)에서 컨테이너 내 git/ssh가 거부되던 두 가지 문제 수정
  - 증상 1 (git): `/workspace` 하위 레포에서
    `fatal: detected dubious ownership in repository at ...` 발생
  - 증상 2 (ssh): `git pull` 시 `Bad owner or permissions on /root/.ssh/config`
    로 원격 접근 실패
  - 회피 시도 시 `git config --global --add safe.directory ...`도
    `error: could not write config file /root/.gitconfig: Device or resource busy`
    로 실패 (`~/.gitconfig`가 `:ro` bind mount이기 때문)
- 원인: macOS Docker Desktop은 VirtioFS 레이어가 bind mount된 호스트 파일의
  owner를 컨테이너 프로세스 UID(root)로 자동 매핑하지만, Linux native Docker는
  호스트 UID를 1:1로 그대로 노출. 컨테이너 root(0)와 다른 UID로 보이므로
  git의 ownership 체크와 ssh의 권한 체크가 모두 거부
- VS Code remote tunnel에서 Study Timer extension이 비활성화되어 일별 JSON이
  생성되지 않던 버그 수정
  - 증상: 4월 29일 이후 `/root/.study-timer/`에 일별 JSON이 더 이상 쌓이지 않음
    (워크스페이스 진입 + 코드 활동에도 불구하고 파일 미생성)
  - 원인: entrypoint가 extension 디렉토리를 `~/.vscode-server/extensions/`로
    복사만 하고 `extensions.json` 레지스트리에는 등록하지 않음. VS Code remote
    agent는 디렉토리만으로는 활성화하지 않고 매 세션마다
    `Marked extension as removed local.study-timer-0.0.1`로 처리하여 activate가
    호출되지 않음. 4월 29일까지는 레지스트리에 우연히 살아있던 항목 덕에
    동작했으나 5월 들어 vscode-server가 `extensions.json`을 재작성하면서 누락됨

### Changed
- `Dockerfile`: `git config --system --add safe.directory '*'`를 빌드 시점에
  주입해 dubious ownership 체크를 영구 비활성화. `:ro` 마운트인 `~/.gitconfig`
  대신 `/etc/gitconfig`(system level)에 기록하므로 호스트 git 설정은 그대로
  보존되고 read-only 마운트와도 충돌하지 않음
- `docker-compose.yml`: `~/.ssh:/root/.ssh:ro` → `~/.ssh:/root/.ssh-host:ro`
  로 마운트 경로를 분리. `:ro` 유지하여 호스트 키는 보호하되, 컨테이너에서
  권한 보정이 가능한 별도 경로에 노출
- `entrypoint.sh`: `setup_ssh()` 함수 추가. 컨테이너 시작 시
  `/root/.ssh-host` → `/root/.ssh`로 복사하고 `chown root:root` + `0700/0600/0644`
  로 SSH 표준 권한을 강제. 컨테이너 로컬 디스크에 복사된 사본을 SSH가 사용
- `entrypoint.sh`: `register_study_timer_extension()` 함수 추가. extension
  디렉토리 복사 직후 `extensions.json` 레지스트리에 study-timer 엔트리를
  idempotent하게 upsert (`/root/.vscode-server/extensions/`와
  `/root/.vscode/extensions/` 양쪽 모두). 기존 엔트리의 `installedTimestamp`는
  보존하여 불필요한 재설치 시그널 방지. JSON 손상 시 빈 배열로 자동 복구하고
  등록 검증 실패 시 fail-fast로 컨테이너 종료
- `Dockerfile`: 첫 apt-get install 블록에 `jq` 패키지 추가
  (`extensions.json` upsert에 사용)

### Notes
- macOS Docker Desktop 환경은 회귀 없음
  - `safe.directory '*'`는 ownership 체크를 한 번 더 통과시키는 no-op
  - SSH 마운트 경로 변경은 `:ro` 그대로라 호스트 파일 영향 없음
  - `setup_ssh`의 `chown`은 macOS에서 어차피 root로 보이므로 no-op,
    `chmod`는 더 엄격한 방향으로 정합되어 SSH 검증 통과
- `safe.directory '*'`로 모든 경로의 ownership 체크를 해제했으나, 컨테이너는
  격리된 root 환경이고 `/workspace`만 외부에서 노출되므로 추가 위험 없음
- Study Timer 등록은 매 컨테이너 시작마다 보장되므로 vscode-server가
  `extensions.json`을 자동으로 재작성해도 다음 재시작에 자동 복구됨

### Migration
- Ubuntu/Linux 호스트:
  ```bash
  git pull
  docker compose down
  docker compose build --no-cache vscode-tunnel
  ./start.sh
  ```
  컨테이너 재진입 후 `git status` / `git pull origin main`이 정상 동작해야 함
- macOS 호스트: 변경 없음 (재빌드만 권장, 동작 동일)
- 모든 호스트: 재빌드 후 `visual-slam-and-perception-learning` 워크스페이스로
  진입하면 study-timer 일별 JSON이 다시 누적됨. 누락 구간(4월 30일 ~ 5월 7일)의
  데이터는 복구 불가

## v1.7.3 (2026-05-07)

### Fixed
- `docker-compose.tailscale.yml`이 `study-timer-data` 볼륨을 `external: true`로
  재선언해 메인 compose의 자동 생성 정의를 덮던 버그 수정
  - 증상: 사용자가 볼륨을 한 번 정리(`docker volume rm study-timer-data`)하면
    `./start.sh` 재기동 시 `external volume "study-timer-data" not found` 에러
    발생 (compose가 외부 사전 존재를 요구하므로 새로 만들지 못함)
  - 원인: multi-file compose 머지에서 후순위 파일의 `external: true`가 메인의
    생성 정의를 override
- `docker-compose.tailscale.yml`의 top-level `volumes:` 선언 제거. 메인
  `docker-compose.yml`이 단일 owner로 볼륨 생성을 책임. `start.sh`가 항상 메인을
  먼저 `-f`로 얹기 때문에 사이드카는 service 블록의 볼륨 참조만으로 충분

### Migration
- Ubuntu에서 v1.7.2 이후 `docker volume rm study-timer-data` 후 기동 실패한 경우:
  `git pull` → `./start.sh` (이번엔 메인 compose가 볼륨을 새로 만들어 주므로 정상)
- 이미 볼륨이 살아있는 호스트는 영향 없음 (둘 다 같은 볼륨을 가리킴)

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
