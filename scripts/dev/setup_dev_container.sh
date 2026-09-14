#!/usr/bin/env bash
# Create (or recreate) the persistent Ubuntu 24.04 / aarch64 development container
# used for AnyREAL development on an Apple Silicon Mac.
#
# Host requirements: OrbStack (or Docker Desktop) with arm64 Linux containers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="${ANYREAL_DEV_NAME:-anyreal-dev}"
IMAGE="${ANYREAL_DEV_IMAGE:-ubuntu:24.04}"
LWC_VOLUME="${ANYREAL_LWC_VOLUME:-anyreal-opt-lwc}"

docker volume create "${LWC_VOLUME}" >/dev/null

if docker inspect "${NAME}" >/dev/null 2>&1; then
    echo "Container ${NAME} already exists; recreating."
    docker rm -f "${NAME}" >/dev/null
fi

docker run -d --name "${NAME}" \
    --platform linux/arm64 \
    --privileged \
    -v "${ROOT}:/work" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${LWC_VOLUME}:/opt/lwc" \
    -w /work \
    "${IMAGE}" sleep infinity

echo "Started ${NAME}. Installing toolchain (this takes a while)..."
"$(dirname "${BASH_SOURCE[0]}")/install_toolchain.sh"
