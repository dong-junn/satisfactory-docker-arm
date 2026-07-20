FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OCI A1 Flex uses Ampere Altra (Armv8.2-A), so use the optimized FEX package.
# The extracted RootFS avoids FUSE and privileged container requirements.
RUN test "$(dpkg --print-architecture)" = "arm64" \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        software-properties-common \
        squashfs-tools \
        tini \
    && add-apt-repository -y ppa:fex-emu/fex \
    && apt-get update \
    && apt-get install -y --no-install-recommends fex-emu-armv8.2 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash satisfactory \
    && mkdir -p \
        /home/satisfactory/Steam \
        /home/satisfactory/dedicated-server \
        /home/satisfactory/.config/Epic \
    && chown -R satisfactory:satisfactory /home/satisfactory

ENV HOME=/home/satisfactory

USER satisfactory
WORKDIR /home/satisfactory

# Download and extract the matching x86-64 Ubuntu RootFS at image build time.
RUN FEXRootFSFetcher -y -x

WORKDIR /home/satisfactory/Steam

RUN curl --fail --silent --show-error --location \
        "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar -xz

COPY --chmod=755 --chown=satisfactory:satisfactory entrypoint.sh /home/satisfactory/entrypoint.sh

WORKDIR /home/satisfactory

ENTRYPOINT ["/usr/bin/tini", "--", "/home/satisfactory/entrypoint.sh"]
