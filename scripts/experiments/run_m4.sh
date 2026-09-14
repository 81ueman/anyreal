#!/usr/bin/env bash
# M4-lite: repeat the M3 scenario N times and collect broker counters.
#
# Compares only functional outcomes here; full native-vs-AnyREAL resource
# measurements are still TODO (PLAN.md §7).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
N="${N:-5}"
CONVERGE_SEC="${CONVERGE_SEC:-10}"
OUT="${ROOT}/.scratch/m4/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUT}"

pass=0
fail=0
for i in $(seq 1 "${N}"); do
    for p in anyreal-run gobgpd; do pkill -9 -x "$p" 2>/dev/null || true; done
    sleep 1
    if STATS=1 CONVERGE_SEC="${CONVERGE_SEC}" timeout 120 \
        "${ROOT}/scripts/experiments/run_m3.sh" >"${OUT}/run${i}.out" 2>&1; then
        pass=$((pass + 1))
        echo "run ${i}: PASS"
    else
        fail=$((fail + 1))
        echo "run ${i}: FAIL"
        tail -5 "${OUT}/run${i}.out"
    fi
    grep -h 'notifications=' "${OUT}/run${i}.out" | sed "s/^/  [run ${i}] /" || true
done

echo "PASS=${pass} FAIL=${fail} (logs in ${OUT})"
[ "${fail}" = "0" ]
