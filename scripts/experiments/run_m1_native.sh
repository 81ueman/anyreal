#!/usr/bin/env bash
# M1: run two unmodified GoBGP nodes natively in separate network namespaces
# over a veth pair, establish a session, advertise/withdraw a prefix.
#
# Intended to run inside the anyreal-dev container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOBGPD="${GOBGPD:-${ROOT}/build/gobgpd}"
GOBGP="${GOBGP:-${ROOT}/build/gobgp}"
LOGDIR="${LOGDIR:-${ROOT}/.scratch/m1}"
RUNID="$(date +%Y%m%d_%H%M%S)"

N1=anyreal-m1-n1
N2=anyreal-m1-n2

cleanup() {
    set +e
    for n in "${N1}" "${N2}"; do
        ip netns pids "${n}" 2>/dev/null | xargs -r kill -9 2>/dev/null
    done
    ip netns delete "${N1}" 2>/dev/null
    ip netns delete "${N2}" 2>/dev/null
}
trap cleanup EXIT

echo "== run ${RUNID} =="
mkdir -p "${LOGDIR}/${RUNID}"

cleanup
ip netns add "${N1}"
ip netns add "${N2}"
ip link add veth1 type veth peer name veth2
ip link set veth1 netns "${N1}"
ip link set veth2 netns "${N2}"
ip -n "${N1}" addr add 10.0.0.1/24 dev veth1
ip -n "${N2}" addr add 10.0.0.2/24 dev veth2
ip -n "${N1}" link set veth1 up
ip -n "${N2}" link set veth2 up
ip -n "${N1}" link set lo up
ip -n "${N2}" link set lo up

ip netns exec "${N1}" "${GOBGPD}" -f "${ROOT}/tests/m1/node1.toml" -l info \
    >"${LOGDIR}/${RUNID}/node1.log" 2>&1 &
ip netns exec "${N2}" "${GOBGPD}" -f "${ROOT}/tests/m1/node2.toml" -l info \
    >"${LOGDIR}/${RUNID}/node2.log" 2>&1 &

echo "-- waiting for session --"
ok=0
for i in $(seq 1 30); do
    st1=$(ip netns exec "${N1}" "${GOBGP}" neighbor 2>/dev/null | grep -c '10\.0\.0\.2.*Establ' || true)
    st2=$(ip netns exec "${N2}" "${GOBGP}" neighbor 2>/dev/null | grep -c '10\.0\.0\.1.*Establ' || true)
    if [ "${st1}" = "1" ] && [ "${st2}" = "1" ]; then
        ok=1; break
    fi
    sleep 1
done
echo "node1 session: ${st1:-?}  node2 session: ${st2:-?} (1=Establ)"
if [ "${ok}" != 1 ]; then
    echo "FAILED: session not established"
    tail -20 "${LOGDIR}/${RUNID}/node1.log" || true
    tail -20 "${LOGDIR}/${RUNID}/node2.log" || true
    exit 1
fi

echo "-- advertise 192.168.1.0/24 from node1 --"
ip netns exec "${N1}" "${GOBGP}" global rib add 192.168.1.0/24
sleep 2
echo "node2 RIB:"
ip netns exec "${N2}" "${GOBGP}" global rib | tee "${LOGDIR}/${RUNID}/node2.rib.txt"

echo "-- withdraw --"
ip netns exec "${N1}" "${GOBGP}" global rib del 192.168.1.0/24
sleep 2
echo "node2 RIB after withdraw:"
ip netns exec "${N2}" "${GOBGP}" global rib | tee "${LOGDIR}/${RUNID}/node2.rib.after.txt"

if grep -q "192.168.1.0/24" "${LOGDIR}/${RUNID}/node2.rib.after.txt"; then
    echo "FAILED: prefix not withdrawn"
    exit 1
fi
echo "M1 PASS"
