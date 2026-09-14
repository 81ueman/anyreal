#!/usr/bin/env bash
# Peer stop/restart at the broker level, using the M2 relay as the backhaul.
# Verifies that a restarted GoBGP node re-establishes the session through the
# broker and receives the peer's routes again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${ROOT}/build/anyreal-run"
RELAY="${ROOT}/build/m2-relay"
GOBGPD="${ROOT}/build/gobgpd"
GOBGP="${ROOT}/build/gobgp"

RELAY_SOCK="/tmp/anyreal-rc-$$.sock"
RIPC="/tmp/anyreal-rc-ripc-$$"
LOGDIR="${ROOT}/.scratch/reconnect/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RIPC}" "${LOGDIR}"

start_node1() {
    "${RUN}" --node 1 --peers "10.0.0.1:10.0.0.2:2" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
        -- "${GOBGPD}" -f "${ROOT}/tests/m1/node1.toml" -l info \
        --api-hosts 127.0.0.1:50071 --pprof-host 127.0.0.1:6071 \
        >>"${LOGDIR}/node1.log" 2>&1 &
    N1_PID=$!
}
start_node2() {
    "${RUN}" --node 2 --peers "10.0.0.2:10.0.0.1:1" --relay "${RELAY_SOCK}" --ripc "${RIPC}" \
        -- "${GOBGPD}" -f "${ROOT}/tests/m1/node2.toml" -l info \
        --api-hosts 127.0.0.1:50072 --pprof-host 127.0.0.1:6072 \
        >>"${LOGDIR}/node2.log" 2>&1 &
    N2_PID=$!
}

wait_established() {
    for _ in $(seq 1 120); do
        if "${GOBGP}" -p 50071 neighbor 2>/dev/null | grep -q '10\.0\.0\.2.*Establ' \
           && "${GOBGP}" -p 50072 neighbor 2>/dev/null | grep -q '10\.0\.0\.1.*Establ'; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

cleanup() {
    set +e
    kill "${RELAY_PID:-}" "${N1_PID:-}" "${N2_PID:-}" 2>/dev/null
    for p in anyreal-run gobgpd m2-relay; do pkill -9 -x "$p" 2>/dev/null; done
    rm -f "${RELAY_SOCK}"
    rm -rf "${RIPC}"
}
trap cleanup EXIT

"${RELAY}" --path "${RELAY_SOCK}" >"${LOGDIR}/relay.log" 2>&1 &
RELAY_PID=$!
sleep 0.5
start_node1
start_node2

echo "-- initial establishment --"
wait_established || { echo "FAILED: initial session"; tail -5 "${LOGDIR}"/*.log; exit 1; }
"${GOBGP}" -p 50071 global rib add 192.168.1.0/24
sleep 2
"${GOBGP}" -p 50072 global rib | tee "${LOGDIR}/node2.rib.initial.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/node2.rib.initial.txt" || { echo "FAILED: prefix not propagated"; exit 1; }
echo "initial: Established and prefix propagated"

# Kill live (non-zombie) processes whose command line contains the pattern.
kill_matching() {
    local pat="$1" d p st cmd
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"
        [ -r "${d}/cmdline" ] || continue
        st=$(awk '{print $3}' "${d}/stat" 2>/dev/null)
        [ "${st}" = "Z" ] && continue
        cmd=$(tr '\0' ' ' <"${d}/cmdline" 2>/dev/null)
        case "${cmd}" in
            *"${pat}"*) kill "${p}" 2>/dev/null || true ;;
        esac
    done
}

echo "-- stop node2 --"
kill_matching "tests/m1/node2.toml"
down=0
for _ in $(seq 1 16); do
    if ! "${GOBGP}" -p 50071 neighbor 2>/dev/null | grep -q '10\.0\.0\.2.*Establ'; then
        down=1; break
    fi
    sleep 0.5
done
if [ "${down}" != 1 ]; then
    echo "FAILED: node1 still sees node2 Established after stop"
    exit 1
fi
echo "node1 session down as expected"

echo "-- restart node2 --"
start_node2
wait_established || { echo "FAILED: session did not recover"; tail -8 "${LOGDIR}/node2.log"; exit 1; }
echo "reconnected: Established"
sleep 2
"${GOBGP}" -p 50072 global rib | tee "${LOGDIR}/node2.rib.after.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/node2.rib.after.txt" || { echo "FAILED: route not re-advertised"; exit 1; }
echo "M2_RECONNECT_PASS (logs in ${LOGDIR})"
