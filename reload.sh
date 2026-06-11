#!/bin/sh
set -e

# 컨테이너 정합성(좀비 네트워크 참조, 누락 사이드카 등)을 회복하기 위한 안전 재기동.
# start.sh와 동일한 compose 오버레이 누적 로직을 사용하여, 일부 compose 파일만
# 빠진 명령으로 재기동되어 사이드카가 옛 network ID를 그대로 가진 채 좀비가 되는
# 사건(v1.8.0 직후 study-timer-http exit 128 케이스)을 막는다.
#
# 동작:
#   1) 같은 COMPOSE_ARGS로 docker compose down 으로 모든 컨테이너/네트워크 정리
#   2) 같은 COMPOSE_ARGS로 docker compose up -d --build 으로 빌드 후 새 컨테이너 생성
# start.sh와의 차별점은 down 유무. start.sh는 in-place 갱신(변경된 컨테이너만 recreate)이라
# 좀비 네트워크/사이드카가 남아있어도 자동 정리되지 않는 반면, reload.sh는 전체를 비우고
# 다시 올리므로 정합성 회복까지 보장. 데이터는 named volume이라 down/up 후에도 보존되며,
# Study Timer는 SIGTERM grace period 동안 deactivate가 호출되어 자기 세션을 최종 flush.

# 누적 args 방식: 기본 compose 파일에 환경 감지 결과를 -f로 얹는다
# (start.sh와 동일한 감지 로직 — 새 오버레이가 늘면 양쪽 모두 갱신할 것)
COMPOSE_ARGS="-f docker-compose.yml"

if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1; then
    echo "GPU detected: enabling GPU support"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.gpu.yml"
fi

if [ -e /dev/video0 ]; then
    echo "Camera detected: enabling ELP stereo camera passthrough"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.camera.yml"
fi

if [ -f docker-compose.local.yml ]; then
    echo "Local override detected: docker-compose.local.yml"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.local.yml"
fi

if [ -f .env ] && grep -qE '^[[:space:]]*TAILSCALE_IP=[^[:space:]#]' .env; then
    echo "Tailscale sidecar detected: enabling study-timer-http"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.tailscale.yml"
fi

echo "Stopping containers..."
docker compose $COMPOSE_ARGS down

echo "Starting containers..."
docker compose $COMPOSE_ARGS up -d --build

# entrypoint 가 vscode CLI 갱신 / SSH 권한 보정 / study-timer 배치 라인을
# 출력할 때까지 짧게 대기한 뒤, 핵심 검증 로그만 추려서 보여준다.
# tunnel 인증 단계는 첫 실행 때 별도로 docker compose logs -f 로 확인.
echo ""
echo "Verifying entrypoint output..."
sleep 8
docker compose $COMPOSE_ARGS logs vscode-tunnel 2>&1 \
    | grep -E "vscode CLI|study-timer|SSH" || true

echo ""
echo "Container status:"
docker ps --filter name=vscode-tunnel --format 'table {{.Names}}\t{{.Status}}'
