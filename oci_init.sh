#!/usr/bin/env bash

set -euo pipefail

# Remove conflicting packages
sudo apt remove -y $(
    dpkg --get-selections \
        docker.io \
        docker-compose \
        docker-compose-v2 \
        docker-doc \
        docker-buildx \
        podman-docker \
        containerd \
        runc \
    | cut -f1
)

# Install prerequisites
sudo apt update
sudo apt install -y \
    ca-certificates \
    curl \
    git \
    vim

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Install Docker Engine
sudo apt update
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Start Docker and enable on boot
sudo systemctl enable --now docker

# Create dedicated user
sudo adduser --disabled-password --gecos "" satisfactory

# Allow Docker without sudo
sudo usermod -aG docker satisfactory