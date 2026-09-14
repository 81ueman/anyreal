#!/usr/bin/env bash
# M2: validate the seccomp user-notification broker end to end against two
# unmodified Go programs, using the minimal M2 relay as the backhaul.
#
# Intended to run inside the anyreal-dev container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${ROOT}/build/anyreal-run"
RELAY="${ROOT}/build/m2-relay"
SERVER="${ROOT}/build/m2-server"
CLIENT="${ROOT}/build/m2-client"

RELAY_SOCK="/tmp/anyreal-m2-$$.sock"
RIPC="/tmp/anyreal-m2-ripc-$$"
mkdir -p "${RIPC}"
LOGDIR="${ROOT}/.scratch/m2/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOGDIR}"

cleanup() {
    set +e
    kill "${RELAY_PID:-}" 2>/dev/null
    kill "${SERVER_PID:-}" 2>/dev/null
    wait 2>/dev/null
    rm -f "${RELAY_SOCK}"
    rm -rf "${RIPC}"
}
trap cleanup EXIT

"${RELAY}" --path "${RELAY_SOCK}" >"${LOGDIR}/relay.log" 2>&1 &
RELAY_PID=$!
sleep 0.5

"${RUN}" --node 1 --peers "10.0.0.1:10.0.0.2:2" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
    -- "${SERVER}" >"${LOGDIR}/server.log" 2>&1 &
SERVER_PID=$!
sleep 1

if ! grep -q SERVER_READY "${LOGDIR}/server.log"; then
    echo "FAILED: server did not start"
    cat "${LOGDIR}/server.log"
    exit 1
fi

set +e
"${RUN}" --node 2 --peers "10.0.0.2:10.0.0.1:1" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
    -- "${CLIENT}" >"${LOGDIR}/client.log" 2>&1
rc=$?
set -e

echo "--- client output ---"
cat "${LOGDIR}/client.log"
echo "--- relay output ---"
cat "${LOGDIR}/relay.log"

if [ "${rc}" != 0 ]; then
    echo "FAILED: client exit ${rc}"
    exit 1
fi
if ! grep -q M2_CLIENT_PASS "${LOGDIR}/client.log"; then
    echo "FAILED: no M2_CLIENT_PASS"
    exit 1
fi
echo "M2 PASS (logs in ${LOGDIR})"
