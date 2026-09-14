#!/usr/bin/env bash
# M3: run two unmodified GoBGP nodes under AnyREAL supervision, connected
# through the *upstream REAL controller* (no LD_PRELOAD, no M2 relay).
#
# The controller launches the nodes itself via the "gobgp" NOS adapter in
# node_ops.cpp (see patches/). Intended to run inside the anyreal-dev container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ANYREAL_ROOT="${ROOT}"
export ANYREAL_CONVERGE_SEC="${CONVERGE_SEC:-30}"
# Make brokers dump syscall counters on exit (captured in anyreal-node*.log).
export ANYREAL_STATS=1
GOBGP="${GOBGP:-${ROOT}/build/gobgp}"
RIPC="/opt/lwc/volumes/ripc"
WAIT="${WAIT:-60}"

LOGDIR="${ROOT}/.scratch/m3/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOGDIR}" "${RIPC}" "${ROOT}/conf/gobgp/topo2"

cleanup() {
    set +e
    kill "${CTRL_PID:-}" 2>/dev/null
    for p in anyreal-run gobgpd; do pkill -9 -x "$p" 2>/dev/null; done
}
trap cleanup EXIT

# The upstream controller hard-codes "/ripc/emu-real-<id>/..." while its own
# sockets live under /opt/lwc/volumes/ripc. Make /ripc point at the same place.
if [ ! -e /ripc ]; then ln -s "${RIPC}" /ripc; fi

cp "${ROOT}/tests/m3/topo2/blueprint.json" "${ROOT}/conf/gobgp/topo2/blueprint.json"
printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/hosts.json"

echo "-- building controller (R2I_DISABLED, TWO_PHASE_DISABLED) --"
make -C "${ROOT}/third_party/REAL/controller" clean >/dev/null
make R2I_DISABLED=1 TWO_PHASE_DISABLED=1 -C "${ROOT}/third_party/REAL/controller" \
    >"${LOGDIR}/controller-build.log" 2>&1

# clean stale state
for p in anyreal-run gobgpd; do pkill -9 -x "$p" 2>/dev/null || true; done
rm -f "${RIPC}/msg_manager_socket" "${RIPC}/actvcnt_manager_socket"

echo "-- starting controller --"
cd "${ROOT}"
"./third_party/REAL/controller/controller" gobgp topo2 "${LOGDIR}" "$(nproc)" "${WAIT}" \
    hosts.json >"${LOGDIR}/controller.log" 2>&1 &
CTRL_PID=$!

echo "-- waiting for session --"
ok=0
for i in $(seq 1 150); do
    if "${GOBGP}" -p 50051 neighbor 2>/dev/null | grep -q '10\.0\.0\.2.*Establ' \
       && "${GOBGP}" -p 50052 neighbor 2>/dev/null | grep -q '10\.0\.0\.1.*Establ'; then
        ok=1; break
    fi
    if ! kill -0 "${CTRL_PID}" 2>/dev/null; then
        echo "controller exited early"; break
    fi
    sleep 0.2
done
if [ "${ok}" != 1 ]; then
    echo "FAILED: session not established"
    echo "--- controller ---"; tail -30 "${LOGDIR}/controller.log"
    echo "--- node logs ---"; tail -15 "${LOGDIR}"/anyreal-node*.log 2>/dev/null || true
    exit 1
fi
echo "session Established (via REAL controller)"

echo "-- advertise 192.168.1.0/24 from node1 --"
"${GOBGP}" -p 50051 global rib add 192.168.1.0/24
sleep 1
"${GOBGP}" -p 50052 global rib | tee "${LOGDIR}/node2.rib.txt"

echo "-- withdraw --"
"${GOBGP}" -p 50051 global rib del 192.168.1.0/24
sleep 1
"${GOBGP}" -p 50052 global rib | tee "${LOGDIR}/node2.rib.after.txt"
if grep -q '192.168.1.0/24' "${LOGDIR}/node2.rib.after.txt"; then
    echo "FAILED: prefix not withdrawn"
    exit 1
fi

if [ "${STATS:-0}" = "1" ]; then
    # Ask the brokers to dump their syscall counters, then exit.
    pkill -TERM -x anyreal-run 2>/dev/null || true
    sleep 1
    echo "--- broker stats ---"
    grep -h anyreal-stats "${LOGDIR}"/anyreal-node*.log 2>/dev/null || true
fi
echo "M3_PASS (logs in ${LOGDIR})"
