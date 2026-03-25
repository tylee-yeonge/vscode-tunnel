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

### 1. 워크스페이스 경로 설정

`docker-compose.yml`에서 마운트할 작업 디렉토리를 지정합니다.

```yaml
volumes:
  - /your/local/workspace:/workspace   # ← 원하는 경로로 변경
```

### 2. 컨테이너 빌드 & 실행

```bash
docker compose up -d --build
```

### 3. VS Code tunnel 인증

컨테이너 최초 실행 시 GitHub 인증이 필요합니다.

```bash
docker compose logs -f
```

로그에 출력되는 URL과 코드를 브라우저에서 입력해 GitHub 계정으로 인증합니다.
인증 정보는 `vscode-cli-data` 볼륨에 저장되므로 **이후 재시작 시 재인증 불필요**합니다.

### 4. 외부에서 접속

인증 완료 후 아래 방법으로 어디서든 접속할 수 있습니다.

- **브라우저**: [https://vscode.dev/tunnel/vsp-learning](https://vscode.dev/tunnel/vsp-learning)
- **VS Code Desktop**: `Remote - Tunnels` 익스텐션 → 터널 이름 선택

> 터널 이름은 `docker-compose.yml`의 `CMD`에서 `--name` 인자로 변경할 수 있습니다.

---

## ⚙️ 볼륨 구성

```yaml
volumes:
  - ./workspace:/workspace          # 작업 디렉토리 (용도에 맞게 변경)
  - ~/.gitconfig:/root/.gitconfig:ro  # 호스트 git 설정 공유
  - ~/.ssh:/root/.ssh:ro            # SSH 키 공유 (git push 등)
  - vscode-cli-data:/root/.vscode-cli  # tunnel 인증 상태 유지
  - ~/.claude:/root/.claude         # Claude Code 인증 공유
```

---

## 🔧 터널 이름 변경

`Dockerfile`의 마지막 `CMD` 또는 `docker-compose.yml`의 `command`에서 수정합니다.

```dockerfile
CMD ["code", "tunnel", "--name", "my-tunnel-name", "--accept-server-license-terms"]
```

---

## 🛑 컨테이너 중지 / 재시작

```bash
# 중지
docker compose down

# 재시작 (재빌드 없이)
docker compose up -d
```
