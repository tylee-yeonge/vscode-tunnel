#!/bin/sh
set -e

# 누적 args 방식: 기본 compose 파일에 환경 감지 결과를 -f로 얹는다
COMPOSE_ARGS="-f docker-compose.yml"

# ROS2 Jazzy 는 Linux 호스트(우분투 PC)에서만 이미지에 설치한다.
# Mac(Darwin) 에서는 INSTALL_ROS 미설정 -> docker-compose.yml 의 기본값 false 로 스킵.
if [ "$(uname -s)" = "Linux" ]; then
    echo "Linux host detected: enabling ROS2 Jazzy install in image build"
    export INSTALL_ROS=true
fi

# GPU 자동 감지 (호스트에서 nvidia-smi 동작 시)
if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1; then
    echo "GPU detected: enabling GPU support"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.gpu.yml"
fi

# SO-ARM101 서보 보드 (.env 의 SO101_FOLLOWER_SERIAL / SO101_LEADER_SERIAL 활성 라인이 모두 있을 때)
# 노드는 팔을 꽂은 뒤 컨테이너 안에서 so101-attach 가 만들므로, 여기서는 팔이 꽂혀
# 있는지 보지 않는다 (팔은 평소에 빼두고 쓸 때만 꽂는다).
if [ -f .env ] \
   && grep -qE '^[[:space:]]*SO101_FOLLOWER_SERIAL=[^[:space:]#]' .env \
   && grep -qE '^[[:space:]]*SO101_LEADER_SERIAL=[^[:space:]#]' .env; then
    echo "SO-ARM101 configured: enabling serial passthrough"
    COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.so101.yml"
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
