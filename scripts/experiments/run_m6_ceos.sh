#!/usr/bin/env bash
# M6: run two ARM64 cEOS-lab nodes under the REAL controller via the cEOS
# preload adapter (no LD_PRELOAD of the whole NOS; only /usr/bin/Bgp is wrapped).
#
# Topology: ceos1=10.70.0.2 (AS65001) <-> ceos2=10.70.0.3 (AS65002) over /ripc.
#
# Prereqs (built separately):
#   third_party/REAL/preload/libpreload.so   (almalinux:9, make IMAGE_CEOS=1)
#   third_party/REAL/controller/controller   (make R2I_DISABLED=1 TWO_PHASE_DISABLED=1)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NET="${NET:-anyreal-m6-net}"
VOL="${VOL:-anyreal-m6-ripc}"
SUBNET="${SUBNET:-10.70.0.0/24}"
C1="${C1:-anyreal-ceos1}"
C2="${C2:-anyreal-ceos2}"
CTRL="${CTRL:-anyreal-m6-ctrl}"
IMG="${IMG:-ceos:4.36.0.1F}"
UBUNTU="${UBUNTU:-ubuntu:24.04}"
IP1="10.70.0.2"
IP2="10.70.0.3"
RIPC="/opt/lwc/volumes/ripc"
LOGDIR="${ROOT}/.scratch/m6/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOGDIR}"

CEOS_ENV=(-e CEOS=1 -e EOS_PLATFORM=ceoslab -e container=docker -e ETBA=1
  -e SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1 -e INTFTYPE=eth -e MAPETH0=1 -e MGMT_INTF=eth0)
CEOS_INIT='exec /sbin/init systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" systemd.setenv="container=docker" systemd.setenv="ETBA=1" systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0"'

cleanup() {
    set +e
    docker rm -f "${CTRL}" "${C1}" "${C2}" >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
    docker volume rm "${VOL}" >/dev/null 2>&1
}
on_exit() { [ "${KEEP:-0}" = "1" ] || cleanup; }
trap on_exit EXIT

cli()  { docker exec "$1" bash -lc "printf '$2' | timeout 60 FastCli -p 15"; }
clic() { docker exec "$1" bash -lc "timeout 25 Cli -p 15 -c \"$2\""; }

wait_cli() {
    for _ in $(seq 1 60); do
        if clic "$1" "show version" 2>/dev/null | grep -q cEOSLab; then return 0; fi
        sleep 2
    done
    echo "FAILED: $1 CLI not ready" >&2
    return 1
}

cleanup
docker network create --subnet "${SUBNET}" "${NET}" >/dev/null
docker volume create "${VOL}" >/dev/null

echo "-- topology config --"
mkdir -p "${ROOT}/third_party/REAL/conf/ceos/topo2"
cp "${ROOT}/tests/m6/topo2/blueprint.json" "${ROOT}/third_party/REAL/conf/ceos/topo2/blueprint.json"
printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/third_party/REAL/hosts.json"

start_ceos() {
    local name="$1" ip="$2"
    docker run -d --name "${name}" --privileged --network "${NET}" --ip "${ip}" \
        -v "${VOL}:/ripc" "${CEOS_ENV[@]}" "${IMG}" bash -c "${CEOS_INIT}" >/dev/null
}

echo "-- starting cEOS nodes --"
start_ceos "${C1}" "${IP1}"
start_ceos "${C2}" "${IP2}"
wait_cli "${C1}"; wait_cli "${C2}"

echo "-- injecting cEOS preload into Bgp only --"

# Build /real_env properly (self and peer addresses).
inject_env() {
    local name="$1" id="$2" self_ip="$3" peer_ip="$4" peer_id="$5"
    docker cp "${ROOT}/third_party/REAL/preload/libpreload.so" "${name}:/usr/lib/libpreload.so"
    docker exec "${name}" bash -lc "
        mkdir -p /ripc/emu-real-${id}
        printf 'NODE_ID=${id}\nPEER_LIST=${self_ip}:${peer_ip}:${peer_id},\nBASE_TS=0\nRT_BASE_TS=0\nMONO_RAW_BASE_TS=0\n' > /real_env
        cat /real_env
        if [ ! -e /usr/bin/Bgp.real ]; then mv /usr/bin/Bgp /usr/bin/Bgp.real; fi
        printf '#!/bin/bash\nexport LD_PRELOAD=/usr/lib/libpreload.so\nexec -a Bgp /usr/bin/Bgp.real \"\$@\"\n' > /usr/bin/Bgp
        chmod 755 /usr/bin/Bgp
    " >"${LOGDIR}/inject-${id}.log" 2>&1
}

inject_env "${C1}" 1 "${IP1}" "${IP2}" 2
inject_env "${C2}" 2 "${IP2}" "${IP1}" 1

echo "-- starting REAL controller (ceos topology) --"
docker run -d --name "${CTRL}" -v "${VOL}:${RIPC}" -v "${ROOT}:/work" \
    -w /work/third_party/REAL -e ANYREAL_CONVERGE_SEC=60 "${UBUNTU}" \
    bash -c 'ln -sfn /opt/lwc/volumes/ripc /ripc; mkdir -p /tmp/m6res/ctrl; exec ./controller/controller ceos topo2 /tmp/m6res "$(nproc)" 300 hosts.json' >/dev/null

# wait for the controller's manager socket to appear in the shared volume
for _ in $(seq 1 30); do
    if docker exec "${CTRL}" bash -lc "test -S ${RIPC}/msg_manager_socket" 2>/dev/null; then break; fi
    sleep 1
done

echo "-- configuring BGP on cEOS nodes --"
cli "${C1}" "configure\nip routing\ninterface Management0\nip address ${IP1}/24\nno shutdown\nexit\nrouter bgp 65001\nrouter-id 1.1.1.1\nneighbor ${IP2} remote-as 65002\nexit\nend\nwrite\n" >"${LOGDIR}/c1-config.log" 2>&1 || true
cli "${C2}" "configure\nip routing\ninterface Management0\nip address ${IP2}/24\nno shutdown\nexit\nrouter bgp 65002\nrouter-id 2.2.2.2\nneighbor ${IP1} remote-as 65001\nexit\nend\nwrite\n" >"${LOGDIR}/c2-config.log" 2>&1 || true

echo "-- waiting for session through the REAL controller --"
ok=0
for _ in $(seq 1 60); do
    if clic "${C1}" "show ip bgp summary" 2>/dev/null | grep -qE "${IP2}.*Estab" \
       && clic "${C2}" "show ip bgp summary" 2>/dev/null | grep -qE "${IP1}.*Estab"; then
        ok=1; break
    fi
    sleep 2
done
clic "${C1}" "show ip bgp summary" | tee "${LOGDIR}/c1-summary.txt"
clic "${C2}" "show ip bgp summary" | tee "${LOGDIR}/c2-summary.txt"
if [ "${ok}" != 1 ]; then
    echo "FAILED: session not established"
    docker logs "${CTRL}" >"${LOGDIR}/controller.log" 2>&1 || true
    tail -20 "${LOGDIR}/controller.log" || true
    exit 1
fi
echo "session Established (via REAL controller)"

echo "-- advertise 192.168.1.0/24 from ceos1 --"
cli "${C1}" "configure\nip route 192.168.1.0/24 Null0\nrouter bgp 65001\nnetwork 192.168.1.0/24\nexit\nend\nwrite\n" >/dev/null 2>&1 || true
sleep 5
clic "${C2}" "show ip bgp" | tee "${LOGDIR}/c2-rib.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/c2-rib.txt" || { echo "FAILED: prefix not propagated"; exit 1; }

echo "-- withdraw --"
cli "${C1}" "configure\nrouter bgp 65001\nno network 192.168.1.0/24\nexit\nend\nwrite\n" >/dev/null 2>&1 || true
sleep 5
clic "${C2}" "show ip bgp" | tee "${LOGDIR}/c2-rib.after.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/c2-rib.after.txt" && { echo "FAILED: prefix not withdrawn"; exit 1; }

echo "M6_CEOS_PASS (logs in ${LOGDIR})"
