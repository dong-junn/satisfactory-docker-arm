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
ARG HOST_UID=1000
ARG HOST_GID=1000

RUN groupadd --gid "${HOST_GID}" satisfactory \
&& useradd --uid "${HOST_UID}" \
          --gid "${HOST_GID}" \
          --create-home \
          --shell /bin/bash \
          satisfactory

USER satisfactory

ENV HOME=/home/satisfactory
ENV XDG_DATA_HOME=/home/satisfactory/.local/share

# 수행 디렉토리 지정
WORKDIR /home/satisfactory

# FexRoot 설정
# FEXRootFSFetcher는 실행 환경에 따라 터미널 애플리케이션 또는 Zenity 애플리케이션으로 동작한다
# https://wiki.fex-emu.com/index.php/Development%3ASetting_up_RootFS

# =================== 대화형 설치 문제 ===================
# FexRoot는 다음과 같이 대화형으로 설정되기 때문에,
# '1\ny\n' & script -qec로 대화형 설치 문제를 해결한다
# Do you wish to extract the squashfs file or use it as-is?
  #Options:
  #	0: Cancel
  #	1: Extract
  #	2: As-Is
  #
  #Response {1-2} or 0 to cancel
  #2
# ===================================================

# =================== 경로 설정 문제 ====================
# FexRoot 설정 이후, RootFS의 경로가 옳바르지 않는 경우가 있다.
# find를 통해 RootFS의 경로를 확인하고,
# .fex-emu/config.json에 확인한 경로를 넣어주는 방식으로 해결한다
# ====================================================
RUN set -eux; \
    printf '1\n' | script -qec \
        'FEXRootFSFetcher -y \
            --distro-name=ubuntu \
            --distro-version=24.04' \
        /dev/null; \
    \
    ROOTFS="$(find "$HOME" \
        -type f \
        -path '*/RootFS/*/usr/bin/dash' \
        -print \
        | sed 's#/usr/bin/dash$##' \
        | head -n 1)"; \
    \
    if [ -z "$ROOTFS" ]; then \
        echo "Extracted FEX RootFS could not be found" >&2; \
        exit 1; \
    fi; \
    \
    echo "Detected FEX RootFS: $ROOTFS"; \
    test -e "$ROOTFS/bin/sh"; \
    \
    mkdir -p "$HOME/.fex-emu"; \
    printf '{\n  "Config": {\n    "RootFS": "%s"\n  }\n}\n' \
        "$ROOTFS" > "$HOME/.fex-emu/Config.json"; \
    \
    cat "$HOME/.fex-emu/Config.json"; \
    FEXBash -c 'test "$(uname -m)" = "x86_64"'

# steamCMD 설치
RUN mkdir -p /home/satisfactory/steamcmd \
    && curl -fsSL \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        -o /tmp/steamcmd_linux.tar.gz \
    && tar -xzf /tmp/steamcmd_linux.tar.gz \
        -C /home/satisfactory/steamcmd \
    && rm -f /tmp/steamcmd_linux.tar.gz

WORKDIR /home/satisfactory/steamcmd
RUN FEXBash -c 'bash ./steamcmd.sh +quit'

# satisfactory 서버파일 설치
CMD ["FEXBash", "-c", "\
bash /home/satisfactory/steamcmd/steamcmd.sh \
  +force_install_dir /home/satisfactory/server-file \
  +login anonymous \
  +app_update 1690800 validate \
  +quit \
&& cd /home/satisfactory/server-file \
&& exec bash ./FactoryServer.sh"]
