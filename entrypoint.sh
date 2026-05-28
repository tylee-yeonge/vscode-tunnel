#!/bin/sh

# VS Code Tunnel 감시 스크립트
# - 터널 프로세스 상태를 주기적으로 확인
# - 좀비/중복 프로세스 감지 시 자동 복구
# - 복구 실패 시 컨테이너 종료 → Docker restart policy로 재시작

TUNNEL_NAME="${TUNNEL_NAME:-my-vscode-tunnel}"
CHECK_INTERVAL=120   # 상태 확인 주기 (초)
MAX_RETRIES=3        # 연속 복구 실패 허용 횟수
STARTUP_GRACE=300    # 초기 시작 후 헬스체크 면제 시간 (초, 인증 대기 고려)

retry_count=0
start_time=0

# VS Code tunnel CLI를 stable 채널의 최신 빌드로 갱신
# 이미지에 burn-in된 CLI는 빌드 시점에 고정되므로 클라이언트(vscode.dev/Desktop)
# 가 갱신되면서 컨테이너 CLI 와 protocol/호환성 격차가 누적될 수 있다.
# 매 컨테이너 시작 시 최신 stable CLI 를 받아 /usr/local/bin/code 를 덮어쓴다.
# - 다운로드 실패(네트워크/CDN 일시 장애) 시 이미지 burn-in 본 CLI 가 그대로 유지됨
# - 갱신 직전 CLI 는 /usr/local/bin/code.prev 로 백업되어 수동 롤백 가능
# - --max-time 30: 네트워크 hang 으로 컨테이너 시작이 무한 지연되는 것을 차단
refresh_vscode_cli() {
    ARCH=$(uname -m | sed "s/aarch64/arm64/; s/x86_64/x64/")
    # 현재 CLI 를 .prev 로 백업 (롤백용)
    if [ -f /usr/local/bin/code ]; then
        cp /usr/local/bin/code /usr/local/bin/code.prev
    fi

    if curl -fsSL --max-time 30 \
        "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-${ARCH}" \
        -o /tmp/code-new.tar.gz; then
        if tar -xzf /tmp/code-new.tar.gz -C /usr/local/bin && rm -f /tmp/code-new.tar.gz; then
            NEW_VER=$(code --version 2>/dev/null | head -1)
            echo "[entrypoint] vscode CLI refreshed: ${NEW_VER}"
        else
            echo "[entrypoint] vscode CLI archive extract failed, keeping previous"
        fi
    else
        echo "[entrypoint] vscode CLI download failed (network/timeout), keeping previous"
    fi
}

# 호스트의 ~/.ssh를 /root/.ssh-host로 마운트하고 컨테이너 root 소유로 복사
# Linux 호스트에서 bind mount된 파일의 UID/perms가 그대로 노출되어
# SSH가 "Bad owner or permissions" 에러로 거부하는 문제를 회피하기 위함
setup_ssh() {
    [ -d /root/.ssh-host ] || return 0
    mkdir -p /root/.ssh
    cp -aT /root/.ssh-host /root/.ssh
    chown -R root:root /root/.ssh
    chmod 700 /root/.ssh
    # private key, config 등은 0600
    find /root/.ssh -type f ! -name 'known_hosts*' ! -name '*.pub' \
        -exec chmod 600 {} \;
    # 공개키와 known_hosts는 0644
    find /root/.ssh -type f \( -name 'known_hosts*' -o -name '*.pub' \) \
        -exec chmod 644 {} \;
    echo "[entrypoint] SSH 키 복사 및 권한 보정 완료"
}

# extensions.json 레지스트리에 study-timer 엔트리를 idempotent하게 upsert
# VS Code remote agent는 디렉토리만으로는 활성화하지 않고 이 레지스트리에
# 등록된 항목만 활성화하므로, 매 컨테이너 시작마다 등록을 보장한다.
# 기존 등록의 installedTimestamp는 보존하여 불필요한 재설치 시그널을 막는다.
register_study_timer_extension() {
    EXT_ID="local.study-timer"
    EXT_VERSION="0.0.1"
    EXT_DIR_NAME="local.study-timer-0.0.1"
    NOW_TS=$(date +%s)000

    for EXT_BASE in "/root/.vscode-server/extensions" "/root/.vscode/extensions"; do
        REG="$EXT_BASE/extensions.json"
        # 파일이 없거나 비어있으면 빈 배열로 초기화
        if [ ! -s "$REG" ]; then
            echo "[]" > "$REG"
        fi
        # 기존 JSON이 손상된 경우에도 복구 가능하도록 빈 배열로 강제
        if ! jq -e 'type == "array"' "$REG" > /dev/null 2>&1; then
            echo "[entrypoint] $REG 손상 감지, 빈 배열로 재초기화"
            echo "[]" > "$REG"
        fi

        TMP="${REG}.tmp"
        jq --arg id "$EXT_ID" \
           --arg ver "$EXT_VERSION" \
           --arg path "$EXT_BASE/$EXT_DIR_NAME" \
           --arg rel "$EXT_DIR_NAME" \
           --argjson nowTs "$NOW_TS" \
           '
           . as $orig
           | ($orig | map(select(.identifier.id == $id))[0].metadata.installedTimestamp // $nowTs) as $ts
           | $orig
           | map(select(.identifier.id != $id))
           | . + [{
               "identifier": { "id": $id },
               "version": $ver,
               "location": { "$mid": 1, "path": $path, "scheme": "file" },
               "relativeLocation": $rel,
               "metadata": {
                 "isApplicationScoped": false,
                 "isMachineScoped": false,
                 "isBuiltin": false,
                 "installedTimestamp": $ts,
                 "pinned": false,
                 "source": "resource",
                 "private": false,
                 "isPreReleaseVersion": false,
                 "hasPreReleaseVersion": false,
                 "preRelease": false
               }
             }]
           ' "$REG" > "$TMP" && mv "$TMP" "$REG"

        # 등록 검증: 실패 시 fail-fast
        if ! jq -e --arg id "$EXT_ID" 'any(.[]; .identifier.id == $id)' "$REG" > /dev/null; then
            echo "[entrypoint] FATAL: $REG 에 $EXT_ID 등록 실패"
            return 1
        fi
    done
    return 0
}

# Study Timer extension을 VS Code server extensions 디렉토리에 배치
# tunnel CLI는 --install-extension을 지원하지 않으므로 직접 복사 방식 사용
deploy_study_timer() {
    SRC="/opt/study-timer-extension"
    EXT_NAME="local.study-timer-0.0.1"
    # tunnel 환경에서 확장이 탐색되는 두 경로 모두에 배치
    for DEST in "/root/.vscode-server/extensions" "/root/.vscode/extensions"; do
        mkdir -p "$DEST"
        rm -rf "$DEST/$EXT_NAME"
        cp -r "$SRC" "$DEST/$EXT_NAME"
    done
    # extensions.json 레지스트리에 등록 (디렉토리만으로는 활성화 안 됨)
    if ! register_study_timer_extension; then
        echo "[entrypoint] study-timer 레지스트리 등록 실패, 컨테이너 종료"
        exit 1
    fi
    # 데이터 디렉토리 (named volume 마운트 대상) 보장
    mkdir -p /root/.study-timer
    chmod 755 /root/.study-timer
    echo "[entrypoint] study-timer extension 배치 및 등록 완료"
}

start_tunnel() {
    # 기존 터널 서비스 종료
    code tunnel kill 2>/dev/null

    # 기존 백그라운드 code 프로세스도 모두 종료
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        kill "$TUNNEL_PID" 2>/dev/null
        wait "$TUNNEL_PID" 2>/dev/null
    fi
    # 혹시 남아있는 code tunnel 프로세스 정리
    pkill -f "code tunnel --name" 2>/dev/null
    sleep 3

    echo "[watchdog] 터널 시작: ${TUNNEL_NAME}"
    code tunnel --name "${TUNNEL_NAME}" --accept-server-license-terms &
    TUNNEL_PID=$!
    start_time=$(date +%s)
    sleep 10
}

check_tunnel_health() {
    # 초기 시작 후 grace period 동안은 헬스체크 면제 (인증 대기 등)
    elapsed=$(($(date +%s) - start_time))
    if [ "$elapsed" -lt "$STARTUP_GRACE" ]; then
        # grace period 중에는 프로세스 생존만 확인
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            echo "[watchdog] 시작 대기 중 (${elapsed}/${STARTUP_GRACE}초)"
            return 0
        else
            echo "[watchdog] grace period 중 프로세스 사망"
            return 1
        fi
    fi

    # 1) 메인 프로세스 생존 확인
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "[watchdog] 터널 프로세스(PID=${TUNNEL_PID})가 죽었음"
        return 1
    fi

    # 2) code tunnel 프로세스 중복 확인 (2개 이상이면 비정상)
    TUNNEL_PROC_COUNT=$(ps aux | grep "[c]ode tunnel --name" | wc -l)
    if [ "$TUNNEL_PROC_COUNT" -gt 1 ]; then
        echo "[watchdog] 터널 프로세스 중복 감지 (${TUNNEL_PROC_COUNT}개)"
        return 1
    fi

    # 3) code tunnel status로 상태 확인
    STATUS=$(code tunnel status 2>/dev/null)
    if [ -z "$STATUS" ]; then
        echo "[watchdog] status 명령 실패"
        return 1
    fi

    TUNNEL_STATE=$(echo "$STATUS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tunnel', {}).get('tunnel', 'Unknown'))
except:
    print('ParseError')
" 2>&1)

    if [ "$TUNNEL_STATE" != "Connected" ]; then
        echo "[watchdog] 터널 상태 비정상: ${TUNNEL_STATE}"
        return 1
    fi

    return 0
}

# 시그널 핸들링 (컨테이너 종료 시 정리)
cleanup() {
    echo "[watchdog] 종료 시그널 수신, 터널 정리 중..."
    code tunnel kill 2>/dev/null
    kill "$TUNNEL_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# VS Code tunnel CLI 갱신 (tunnel 시작 전, 실패 시 burn-in 본 사용)
refresh_vscode_cli

# SSH 키 권한 보정 (tunnel 시작 전)
setup_ssh

# Study Timer extension 배치 (tunnel 시작 전)
deploy_study_timer

# 최초 시작
start_tunnel

# 감시 루프
while true; do
    sleep "$CHECK_INTERVAL" &
    wait $!

    if check_tunnel_health; then
        retry_count=0
    else
        retry_count=$((retry_count + 1))
        echo "[watchdog] 비정상 감지 (${retry_count}/${MAX_RETRIES})"

        if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
            echo "[watchdog] 최대 재시도 초과, 컨테이너 종료"
            exit 1
        fi

        echo "[watchdog] 터널 재시작 시도..."
        start_tunnel
    fi
done
