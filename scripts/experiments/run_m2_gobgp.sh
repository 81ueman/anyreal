#!/usr/bin/env bash
# M2b: run two *unmodified* GoBGP nodes under AnyREAL supervision, with the M2
# relay as the backhaul. Validates the broker against a real NOS before the
# REAL controller is wired in (M3).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${ROOT}/build/anyreal-run"
RELAY="${ROOT}/build/m2-relay"
GOBGPD="${GOBGPD:-${ROOT}/build/gobgpd}"
GOBGP="${GOBGP:-${ROOT}/build/gobgp}"

RELAY_SOCK="/tmp/anyreal-m2b-$$.sock"
RIPC="/tmp/anyreal-m2b-ripc-$$"
LOGDIR="${ROOT}/.scratch/m2b/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RIPC}" "${LOGDIR}"

cleanup() {
    set +e
    kill "${RELAY_PID:-}" "${N1_PID:-}" "${N2_PID:-}" 2>/dev/null
    wait 2>/dev/null
    rm -f "${RELAY_SOCK}"
    rm -rf "${RIPC}"
}
trap cleanup EXIT

"${RELAY}" --path "${RELAY_SOCK}" >"${LOGDIR}/relay.log" 2>&1 &
RELAY_PID=$!
sleep 0.5

"${RUN}" --node 1 --peers "10.0.0.1:10.0.0.2:2" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
    -- "${GOBGPD}" -f "${ROOT}/tests/m1/node1.toml" -l info \
    --api-hosts 127.0.0.1:50051 >"${LOGDIR}/node1.log" 2>&1 &
N1_PID=$!

"${RUN}" --node 2 --peers "10.0.0.2:10.0.0.1:1" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
    -- "${GOBGPD}" -f "${ROOT}/tests/m1/node2.toml" -l info \
    --api-hosts 127.0.0.1:50052 --pprof-host 127.0.0.1:6062 >"${LOGDIR}/node2.log" 2>&1 &
N2_PID=$!

echo "-- waiting for session --"
ok=0
for i in $(seq 1 40); do
    if "${GOBGP}" -p 50051 neighbor 2>/dev/null | grep -q '10\.0\.0\.2.*Establ' \
       && "${GOBGP}" -p 50052 neighbor 2>/dev/null | grep -q '10\.0\.0\.1.*Establ'; then
        ok=1; break
    fi
    sleep 0.5
done
if [ "${ok}" != 1 ]; then
    echo "FAILED: session not established"
    echo "--- node1 ---"; tail -15 "${LOGDIR}/node1.log"
    echo "--- node2 ---"; tail -15 "${LOGDIR}/node2.log"
    echo "--- relay ---"; tail -10 "${LOGDIR}/relay.log"
    exit 1
fi
echo "session Established"

echo "-- advertise 192.168.1.0/24 from node1 --"
"${GOBGP}" -p 50051 global rib add 192.168.1.0/24
sleep 2
"${GOBGP}" -p 50052 global rib | tee "${LOGDIR}/node2.rib.txt"

echo "-- withdraw --"
"${GOBGP}" -p 50051 global rib del 192.168.1.0/24
sleep 2
"${GOBGP}" -p 50052 global rib | tee "${LOGDIR}/node2.rib.after.txt"
if grep -q '192.168.1.0/24' "${LOGDIR}/node2.rib.after.txt"; then
    echo "FAILED: prefix not withdrawn"
    exit 1
fi
echo "M2B_GOBGP_PASS (logs in ${LOGDIR})"
