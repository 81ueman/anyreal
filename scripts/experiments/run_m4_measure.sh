#!/usr/bin/env bash
# M4 measurement: native vs AnyREAL for 2-node GoBGP.
#  - time from process start to "session Established"
#  - peak RSS (VmHWM) of gobgpd, and for AnyREAL also of anyreal-run and controller
#
# Runs inside the anyreal-dev container. Prints a summary table.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOBGPD="${GOBGPD:-${ROOT}/build/gobgpd}"
GOBGP="${GOBGP:-${ROOT}/build/gobgp}"
RUN="${ROOT}/build/anyreal-run"
OUT="${ROOT}/.scratch/measure/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUT}"

hwm() { awk '/VmHWM/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }  # kB
sum_hwm_by_name() { # name -> sum kB of live processes
    local total=0
    for p in $(pgrep -x "$1" 2>/dev/null); do
        [ "$(awk '{print $3}' /proc/$p/stat 2>/dev/null)" = "Z" ] && continue
        total=$((total + $(hwm "$p")))
    done
    echo "$total"
}

cleanup() {
    set +e
    for n in anyreal-m4-n1 anyreal-m4-n2; do ip netns pids "$n" 2>/dev/null | xargs -r kill -9 2>/dev/null; ip netns delete "$n" 2>/dev/null; done
    for p in anyreal-run gobgpd; do pkill -9 -x "$p" 2>/dev/null; done
    rm -f /opt/lwc/volumes/ripc/msg_manager_socket 2>/dev/null
}
trap cleanup EXIT

# ---------- native ----------
native_measure() {
    cleanup
    ip netns add anyreal-m4-n1; ip netns add anyreal-m4-n2
    ip link add veth1 type veth peer name veth2
    ip link set veth1 netns anyreal-m4-n1; ip link set veth2 netns anyreal-m4-n2
    ip -n anyreal-m4-n1 addr add 10.0.0.1/24 dev veth1; ip -n anyreal-m4-n2 addr add 10.0.0.2/24 dev veth2
    for n in anyreal-m4-n1 anyreal-m4-n2; do ip -n "$n" link set lo up; done
    ip -n anyreal-m4-n1 link set veth1 up; ip -n anyreal-m4-n2 link set veth2 up

    local t0; t0=$(date +%s.%N)
    ip netns exec anyreal-m4-n1 "${GOBGPD}" -f "${ROOT}/tests/m1/node1.toml" -l error --api-hosts 127.0.0.1:50051 --pprof-host 127.0.0.1:6061 >/dev/null 2>&1 &
    ip netns exec anyreal-m4-n2 "${GOBGPD}" -f "${ROOT}/tests/m1/node2.toml" -l error --api-hosts 127.0.0.1:50052 --pprof-host 127.0.0.1:6062 >/dev/null 2>&1 &
    for _ in $(seq 1 200); do
        if ip netns exec anyreal-m4-n1 "${GOBGP}" -p 50051 neighbor 2>/dev/null | grep -qE '10\.0\.0\.2.*Establ' && \
           ip netns exec anyreal-m4-n2 "${GOBGP}" -p 50052 neighbor 2>/dev/null | grep -qE '10\.0\.0\.1.*Establ'; then break; fi
        sleep 0.1
    done
    local t1; t1=$(date +%s.%N)
    sleep 1
    local m; m=$(sum_hwm_by_name gobgpd)
    echo "native $t0 $t1 $m"
}

# ---------- AnyREAL (controller path, like M3) ----------
anyreal_measure() {
    cleanup
    mkdir -p /opt/lwc/volumes/ripc; [ -e /ripc ] || ln -s /opt/lwc/volumes/ripc /ripc
    mkdir -p "${ROOT}/conf/gobgp/topo2"
    cp "${ROOT}/tests/m3/topo2/blueprint.json" "${ROOT}/conf/gobgp/topo2/blueprint.json"
    printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/hosts.json"
    export ANYREAL_ROOT="${ROOT}" ANYREAL_CONVERGE_SEC=120
    make clean -C "${ROOT}/third_party/REAL/controller" >/dev/null 2>&1
    make R2I_DISABLED=1 TWO_PHASE_DISABLED=1 -C "${ROOT}/third_party/REAL/controller" >/dev/null 2>&1

    local t0; t0=$(date +%s.%N)
    ( cd "${ROOT}" && ./third_party/REAL/controller/controller gobgp topo2 "${OUT}" "$(nproc)" 300 hosts.json >"${OUT}/controller.log" 2>&1 ) &
    for _ in $(seq 1 200); do
        if "${GOBGP}" -p 50051 neighbor 2>/dev/null | grep -qE '10\.0\.0\.2.*Establ' && \
           "${GOBGP}" -p 50052 neighbor 2>/dev/null | grep -qE '10\.0\.0\.1.*Establ'; then break; fi
        sleep 0.1
    done
    local t1; t1=$(date +%s.%N)
    sleep 1
    local mg mb mc
    mg=$(sum_hwm_by_name gobgpd); mb=$(sum_hwm_by_name anyreal-run)
    mc=$(for p in $(pgrep -x controller 2>/dev/null); do hwm "$p"; done | awk '{s+=$1} END{print s+0}')
    echo "anyreal $t0 $t1 $mg $mb ${mc:-0}"
}

set +e
echo "run,estab_sec,gobgpd_kB,broker_kB,controller_kB" | tee "${OUT}/summary.csv"
read -r _ n0 n1 nm <<<"$(native_measure)"
printf "native,%.2f,%s,,\n" "$(awk -v a="$n0" -v b="$n1" 'BEGIN{print b-a}')" "$nm" | tee -a "${OUT}/summary.csv"
read -r _ a0 a1 am bm cm <<<"$(anyreal_measure)"
printf "anyreal,%.2f,%s,%s,%s\n" "$(awk -v a="$a0" -v b="$a1" 'BEGIN{print b-a}')" "$am" "$bm" "${cm:-0}" | tee -a "${OUT}/summary.csv"
cleanup
echo "logs in ${OUT}"
