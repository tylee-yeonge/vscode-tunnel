#!/bin/sh

# GPU 자동 감지 후 적절한 compose 설정으로 컨테이너 시작
if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1; then
    echo "GPU detected, starting with GPU support"
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
else
    echo "No GPU detected, starting without GPU"
    docker compose up -d --build
fi
