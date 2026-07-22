FROM ubuntu:24.04

# fex-emu 설치
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        software-properties-common \
        ca-certificates \
        curl \
        sudo \
        util-linux \
    && add-apt-repository -y ppa:fex-emu/fex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        fex-emu-armv8.2 \
    && rm -rf /var/lib/apt/lists/*

# 사용자 설정
RUN useradd --create-home --shell /bin/bash satisfactory
USER satisfactory

ENV HOME=/home/satisfactory
ENV XDG_DATA_HOME=/home/satisfactory/.local/share

# 수행 디렉토리 지정
WORKDIR /home/satisfactory

# FexRoot 설정
RUN printf '1\ny\n' | script -qec \
    'FEXRootFSFetcher -y \
        --distro-name=ubuntu \
        --distro-version=24.04' \
    /dev/null


