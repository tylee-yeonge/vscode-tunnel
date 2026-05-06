#!/bin/sh
set -e

# 누적 args 방식: 기본 compose 파일에 환경 감지 결과를 -f로 얹는다
COMPOSE_ARGS="-f docker-compose.yml"

# GPU 자동 감지 (호스트에서 nvidia-smi 동작 시)
if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1; then
    echo "GPU detected: enabling GPU support"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.gpu.yml"
fi

# 머신별 로컬 오버라이드 (gitignored, 데이터셋 마운트 등)
if [ -f docker-compose.local.yml ]; then
    echo "Local override detected: docker-compose.local.yml"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.local.yml"
fi

# Multi-host study-timer 사이드카 (TAILSCALE_IP 활성화 시)
if [ -f .env ] && grep -qE '^[[:space:]]*TAILSCALE_IP=[^[:space:]#]' .env; then
    echo "Tailscale sidecar detected: enabling study-timer-http"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.tailscale.yml"
fi

docker compose $COMPOSE_ARGS up -d --build
