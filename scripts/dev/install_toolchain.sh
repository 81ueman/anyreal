#!/usr/bin/env bash
# Install the build/runtime toolchain inside the anyreal-dev container.
set -euo pipefail

NAME="${ANYREAL_DEV_NAME:-anyreal-dev}"
GO_VERSION="${ANYREAL_GO_VERSION:-1.23.6}"

docker exec -e "GO_VERSION=${GO_VERSION}" "${NAME}" bash -lc '
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential make perl pkg-config \
  python3-venv python3-pip python3-dev \
  iproute2 iputils-ping netcat-openbsd tcpdump ethtool \
  jq ripgrep tree rsync gdb strace ltrace lsof \
  unzip zip tar xz-utils vim tmux less nano htop procps \
  git ca-certificates gnupg curl \
  autoconf automake libtool bison flex cmake \
  docker.io

if [ ! -x /usr/local/go/bin/go ]; then
  curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz"
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi

if [ ! -x /usr/local/cargo/bin/cargo ]; then
  export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --no-modify-path --profile minimal --default-toolchain stable
fi

/usr/local/go/bin/go version
/usr/local/cargo/bin/cargo --version
echo TOOLCHAIN_OK
'
