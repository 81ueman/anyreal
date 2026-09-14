#!/usr/bin/env bash
# Fetch the pinned upstream REAL artifact into third_party/REAL.
set -euo pipefail

REPO_URL="https://github.com/ants-xjtu/REAL-artifact-evaluation.git"
COMMIT="52f440cfb597fe9440ed3e862f98bd5bbf9171c4"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/third_party/REAL"

mkdir -p "${ROOT}/third_party"

if [ -d "${DEST}/.git" ]; then
    echo "Upstream already present at ${DEST}"
else
    echo "Cloning ${REPO_URL} -> ${DEST}"
    git clone --filter=blob:none --no-checkout "${REPO_URL}" "${DEST}"
fi

cd "${DEST}"
git fetch --depth 1 origin "${COMMIT}"
git checkout --detach "${COMMIT}"
echo "Upstream REAL at ${COMMIT}:"
git rev-parse HEAD
