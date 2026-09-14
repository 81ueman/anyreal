#!/usr/bin/env bash
# Apply the AnyREAL patches to the pinned upstream checkout in third_party/REAL.
#
# Patches are applied in filename order. Re-running is safe: already-applied
# patches are detected and skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ROOT}/third_party/REAL"

if [ ! -d "${UPSTREAM}/.git" ]; then
    echo "Upstream not found at ${UPSTREAM}; run scripts/fetch_upstream.sh first." >&2
    exit 1
fi

cd "${UPSTREAM}"
status=0
for p in "${ROOT}"/patches/*.patch; do
    name="$(basename "${p}")"
    if git apply --check "${p}" 2>/dev/null; then
        git apply "${p}"
        echo "applied  ${name}"
    elif git apply --reverse --check "${p}" 2>/dev/null; then
        echo "skipped  ${name} (already applied)"
    else
        echo "FAILED   ${name} (does not apply cleanly)" >&2
        status=1
    fi
done
exit "${status}"
