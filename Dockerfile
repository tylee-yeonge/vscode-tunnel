# 빌드 베이스 이미지. 머신별 .env의 BASE_IMAGE로 오버라이드 가능
# 기본값: ubuntu:24.04 (Mac/CPU)
# CUDA 학습용: nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04
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
    jq \
    unzip \
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
# Python 패키지: nuScenes devkit, rerun (자율주행 데이터셋/시각화)
# Ubuntu 24.04의 PEP 668 보호를 우회하기 위해 --break-system-packages 사용
# (이미지 전용 환경이고 OpenCV가 이미 system Python에 cv2를 설치한 상태이므로
#  venv 분리는 cv2 사용을 막아 부적합)
# ========================================
RUN apt-get update && apt-get install -y \
    python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --break-system-packages \
        nuscenes-devkit \
        rerun-sdk

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

# git credential helper + bind mount된 /workspace 등의 dubious ownership 우회
# (호스트 UID와 컨테이너 root UID가 다른 Linux 호스트에서 git이 거부하는 문제 방지)
RUN git config --system credential.helper store \
 && git config --system --add safe.directory '*'

# ========================================
# ROS2 Jazzy (Ubuntu 24.04 / noble 전용)
# INSTALL_ROS=true 일 때만 설치. start.sh / reload.sh 가 Linux 호스트(우분투 PC)에서
# 자동으로 true 를 export 하며, Mac(Darwin) 에서는 INSTALL_ROS 가 false 로 남아
# 이 블록 전체가 스킵된다. desktop + cv-bridge + image-transport 설치.
# 설치 시 interactive bash 가 자동으로 환경을 잡도록 /root/.bashrc 에 setup.bash 를 source.
# ========================================
ARG INSTALL_ROS=false
RUN if [ "$INSTALL_ROS" = "true" ]; then \
        set -eux; \
        apt-get update; \
        apt-get install -y --no-install-recommends software-properties-common; \
        add-apt-repository -y universe; \
        ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | jq -r .tag_name); \
        UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME"); \
        curl -fsSL -o /tmp/ros2-apt-source.deb "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${UBUNTU_CODENAME}_all.deb"; \
        apt-get install -y /tmp/ros2-apt-source.deb; \
        rm -f /tmp/ros2-apt-source.deb; \
        apt-get update; \
        apt-get install -y \
            ros-jazzy-desktop \
            ros-jazzy-cv-bridge \
            ros-jazzy-image-transport; \
        echo 'source /opt/ros/jazzy/setup.bash' >> /root/.bashrc; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "INSTALL_ROS=false: skipping ROS2 Jazzy installation"; \
    fi

# ========================================
# 타임존 고정 (Asia/Seoul)
# ubuntu:24.04 기본 /etc/localtime이 Etc/UTC를 가리키는 상태로 남아있어,
# IANA tz 이름을 /etc/localtime 심볼릭 링크에서 추출하는 도구(예: code tunnel CLI의
# iana-time-zone crate)가 UTC로 동작하는 문제가 발생함. 이미지 단에서 영구 고정.
# 캐시 무효화 영향 최소화를 위해 OpenCV 빌드 이후 단계에 배치.
# ========================================
ARG TZ=Asia/Seoul
ENV TZ=${TZ}
RUN apt-get update && apt-get install -y --no-install-recommends tzdata \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata \
    && rm -rf /var/lib/apt/lists/*

# ========================================
# HuggingFace 캐시 경로 고정
# 기본값(~/.cache/huggingface)과 동일 경로지만, named volume 마운트 지점을
# 명시적으로 박아 두기 위함. 실제 영속화는 docker-compose.yml 의 hf-cache
# named volume 마운트가 담당한다(이 ENV 단독으로는 보존되지 않음).
# transformers / datasets / huggingface_hub / hub modules 가 모두 HF_HOME 을 따른다.
# ========================================
ENV HF_HOME=/root/.cache/huggingface

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

