# vscode-tunnel-for-mac

어디서든 VS Code로 원격 접속할 수 있는 Docker 기반 개발 환경입니다.  
`docker-compose.yml`의 볼륨 경로만 바꾸면 **어떤 작업 디렉토리든** VS Code tunnel을 통해 외부에서 접근할 수 있습니다.

---

## 📦 포함 구성

| 구성 요소 | 버전 / 내용 |
|-----------|------------|
| Base Image | Ubuntu 24.04 |
| OpenCV | 4.10.0 (소스 빌드, contrib 포함) |
| VS Code CLI | stable / `cli-alpine-arm64` (Apple Silicon 기준) |
| Claude Code | 최신 버전 (native installer) |
| 빌드 도구 | CMake, Ninja, GDB, build-essential |

> ⚠️ VS Code CLI는 **ARM64(Apple Silicon Mac)** 기준으로 빌드되어 있습니다.  
> x86_64 환경에서는 `Dockerfile` 내 CLI 다운로드 URL의 `cli-alpine-arm64`를 `cli-alpine-x64`로 변경하세요.

---

## 🚀 빠른 시작

### 1. 환경 변수 파일 설정

`.env.sample`을 복사하여 `.env` 파일을 만들고, 터널 이름을 지정합니다.

```bash
cp .env.sample .env
```

`.env` 파일을 열어 `TUNNEL_NAME`을 원하는 이름으로 변경합니다.

```env
TUNNEL_NAME=my-dev-tunnel   # ← 소문자, 숫자, 하이픈만 사용 가능 (전 세계 고유해야 함)
```

> 🔒 `.env` 파일은 `.gitignore`에 등록되어 있어 **Git에 커밋되지 않습니다**.  
> 반드시 `.env.sample`만 커밋하고, 실제 값은 `.env`에 보관하세요.

### 2. 워크스페이스 경로 설정 (선택)

`.env` 파일의 `WORKSPACE_PATH`로 마운트할 작업 디렉토리를 지정합니다.
기본값은 프로젝트 내 `./workspace` 폴더입니다.

```env
WORKSPACE_PATH=./workspace          # 기본값
WORKSPACE_PATH=/Users/me/projects   # 또는 절대 경로 지정
```

### 3. 컨테이너 빌드 & 실행

```bash
docker compose up -d --build
```

### 4. VS Code tunnel 인증

컨테이너 최초 실행 시 GitHub 인증이 필요합니다.

```bash
docker compose logs -f
```

로그에 출력되는 URL과 코드를 브라우저에서 입력해 GitHub 계정으로 인증합니다.  
인증 정보는 `vscode-cli-data` 볼륨에 저장되므로 **이후 재시작 시 재인증 불필요**합니다.

### 5. 외부에서 접속

인증 완료 후 아래 방법으로 어디서든 접속할 수 있습니다.

- **브라우저**: `https://vscode.dev/tunnel/<TUNNEL_NAME>`
- **VS Code Desktop**: `Remote - Tunnels` 익스텐션 → 터널 이름 선택

---

## ⚙️ 볼륨 구성

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace     # 작업 디렉토리 (.env에서 경로 설정)
  - ~/.gitconfig:/root/.gitconfig:ro  # 호스트 git 설정 공유
  - ~/.ssh:/root/.ssh:ro            # SSH 키 공유 (git push 등)
  - vscode-cli-data:/root/.vscode-cli  # tunnel 인증 상태 유지
  - ~/.claude:/root/.claude         # Claude Code 인증 공유
```

---

## 🔧 터널 이름 변경

터널 이름은 `.env` 파일의 `TUNNEL_NAME` 변수로 관리합니다.

```env
# .env
TUNNEL_NAME=my-new-tunnel-name
```

이름 변경 후 컨테이너를 재시작하면 적용됩니다.

```bash
docker compose down
docker compose up -d
```

> 터널 이름은 소문자, 숫자, 하이픈만 허용되며 전 세계적으로 고유해야 합니다.  
> 기본값은 `my-vscode-tunnel`입니다 (`.env` 파일이 없을 경우 Dockerfile 기본값 사용).

---

## 🛑 컨테이너 중지 / 재시작

```bash
# 중지
docker compose down

# 재시작 (재빌드 없이)
docker compose up -d
```

---

## 🔄 자동 복구 (Watchdog)

터널 프로세스가 좀비 상태가 되어 외부 접속이 불가능해지는 문제를 방지합니다.

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

## 📁 파일 구성

```
.
├── Dockerfile          # 이미지 정의 (Ubuntu 24.04 + OpenCV + VS Code CLI + Claude Code)
├── docker-compose.yml  # 컨테이너 실행 설정
├── entrypoint.sh       # 터널 watchdog 스크립트 (자동 복구)
├── .env                # 환경 변수 (TUNNEL_NAME 등) – Git 미포함
├── .env.sample         # 환경 변수 템플릿 – Git 포함
├── .gitignore          # .env, workspace/, .DS_Store 등 제외
└── workspace/          # 컨테이너에 마운트되는 작업 디렉토리 – Git 미포함
```
