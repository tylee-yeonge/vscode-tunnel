# 빌드 베이스 이미지. 머신별 .env의 BASE_IMAGE로 오버라이드 가능
# 기본값: ubuntu:24.04 (Mac/CPU)
# CUDA 학습용: nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04
ARG BASE_IMAGE=ubuntu:24.04

# ========================================
# Stage 1: Study Timer extension 빌드 (TypeScript -> JS)
# ========================================
FROM node:20-alpine AS study-timer-builder

WORKDIR /build
COPY extensions/study-timer/package.json extensions/study-timer/tsconfig.json ./
RUN npm install --no-audit --no-fund
COPY extensions/study-timer/src ./src
RUN npm run compile

# ========================================
# Stage 2: 최종 런타임 이미지
# ========================================
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# ========================================
# 기본 도구 + cmake + git + 빌드 도구
# ========================================
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    cmake \
    build-essential \
    ninja-build \
    gdb \
    pkg-config \
    ca-certificates \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# ========================================
# OpenCV 의존성 패키지
# ========================================
RUN apt-get update && apt-get install -y \
    # GUI (headless 환경에서는 highgui 미사용이지만 빌드 호환성 위해 포함)
    libgtk-3-dev \
    # 이미지 포맷
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libwebp-dev \
    openexr \
    libopenexr-dev \
    # 비디오 코덱 / 미디어
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libv4l-dev \
    libxvidcore-dev \
    libx264-dev \
    # GStreamer
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    # 수학 / 선형대수
    libatlas-base-dev \
    gfortran \
    libeigen3-dev \
    # 병렬처리
    libtbb-dev \
    # Python 바인딩 (선택)
    python3-dev \
    python3-numpy \
    && rm -rf /var/lib/apt/lists/*

# ========================================
# OpenCV 소스 빌드
# ========================================
ARG OPENCV_VERSION=4.10.0

RUN cd /tmp && \
    git clone --depth 1 --branch ${OPENCV_VERSION} https://github.com/opencv/opencv.git && \
    git clone --depth 1 --branch ${OPENCV_VERSION} https://github.com/opencv/opencv_contrib.git && \
    mkdir -p opencv/build && cd opencv/build && \
    cmake .. -G Ninja \
        -D CMAKE_BUILD_TYPE=RELEASE \
        -D CMAKE_INSTALL_PREFIX=/usr/local \
        -D OPENCV_EXTRA_MODULES_PATH=/tmp/opencv_contrib/modules \
        -D OPENCV_GENERATE_PKGCONFIG=ON \
        -D BUILD_EXAMPLES=OFF \
        -D BUILD_TESTS=OFF \
        -D BUILD_PERF_TESTS=OFF \
        -D BUILD_opencv_python3=ON \
        -D INSTALL_PYTHON_EXAMPLES=OFF \
        -D INSTALL_C_EXAMPLES=OFF && \
    ninja -j$(nproc) && \
    ninja install && \
    ldconfig && \
    rm -rf /tmp/opencv /tmp/opencv_contrib

# ========================================
# VS Code CLI 설치 (tunnel용, 호스트 아키텍처 자동 감지)
# ========================================
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        arm64) ARCH="arm64" ;; \
        amd64) ARCH="x64" ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-${ARCH}" \
    -o /tmp/vscode-cli.tar.gz \
    && tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin \
    && rm /tmp/vscode-cli.tar.gz

# ========================================
# Claude Code 설치 (native installer)
# ========================================
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

# git credential helper
RUN git config --system credential.helper store

WORKDIR /workspace

# ========================================
# Study Timer extension 스테이징
# entrypoint에서 ~/.vscode-server/extensions/ 로 복사
# ========================================
COPY --from=study-timer-builder /build/out /opt/study-timer-extension/out
COPY --from=study-timer-builder /build/package.json /opt/study-timer-extension/package.json

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]

