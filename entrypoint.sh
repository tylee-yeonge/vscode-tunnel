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
