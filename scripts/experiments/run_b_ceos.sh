#!/usr/bin/env bash
# B: run cEOS under the AnyREAL *seccomp broker* (no LD_PRELOAD), 2 nodes, via
# the REAL controller. The broker supervises the NOS init and virtualizes the
# BGP sockets of all descendants.
#
# Prereqs:
#   build/anyreal-run-ala9   (launcher+broker built on almalinux:9)
#   third_party/REAL/controller/controller (R2I_DISABLED, TWO_PHASE_DISABLED)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="${ROOT}/build/anyreal-run-ala9"
NET="anyreal-b-net"; VOL="anyreal-b-ripc"; SUBNET="10.71.0.0/24"
CTRL="anyreal-b-ctrl"; IMG="${IMG:-ceos:4.36.0.1F}"; UBUNTU="${UBUNTU:-ubuntu:24.04}"
RIPC="/opt/lwc/volumes/ripc"
N1="anyreal-b1"; N2="anyreal-b2"; IP1="10.71.0.11"; IP2="10.71.0.12"
LOGDIR="${ROOT}/.scratch/b/$(date +%Y%m%d_%H%M%S)"; mkdir -p "${LOGDIR}"
[ -x "${RUN}" ] || { echo "missing ${RUN}"; exit 1; }

CEOS_ENV=(-e CEOS=1 -e EOS_PLATFORM=ceoslab -e container=docker -e ETBA=1
  -e SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1 -e INTFTYPE=eth -e MAPETH0=1 -e MGMT_INTF=eth0)
SETENV='systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" systemd.setenv="container=docker" systemd.setenv="ETBA=1" systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0"'

cleanup() { set +e; docker rm -f "${CTRL}" "${N1}" "${N2}" >/dev/null 2>&1; docker network rm "${NET}" >/dev/null 2>&1; docker volume rm "${VOL}" >/dev/null 2>&1; }
on_exit() { [ "${KEEP:-0}" = "1" ] || cleanup; }
trap on_exit EXIT

cli()  { docker exec "$1" bash -lc "printf '$2' | timeout 60 FastCli -p 15" >/dev/null 2>&1 || true; }
clic() { docker exec "$1" bash -lc "timeout 25 Cli -p 15 -c \"$2\" 2>/dev/null"; }

cleanup
docker network create --subnet "${SUBNET}" "${NET}" >/dev/null
docker volume create "${VOL}" >/dev/null
mkdir -p "${ROOT}/third_party/REAL/conf/ceos/topo2"
cp "${ROOT}/tests/m6/topo2/blueprint.json" "${ROOT}/third_party/REAL/conf/ceos/topo2/blueprint.json" 2>/dev/null || true
# overwrite blueprint with the B addresses
python3 - <<PY
import json
r=[{"idx":1,"neighbors":[{"self_ip":"${IP1}","neighbor_ip":"${IP2}","peeridx":2}]},
   {"idx":2,"neighbors":[{"self_ip":"${IP2}","neighbor_ip":"${IP1}","peeridx":1}]}]
json.dump({"routers":r}, open("${ROOT}/third_party/REAL/conf/ceos/topo2/blueprint.json","w"), indent=2)
PY
printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/third_party/REAL/hosts.json"

start_node() {
    local name="$1" id="$2" ip="$3" peers="$4"
    docker run -d --name "${name}" --privileged --network "${NET}" --ip "${ip}" \
        -v "${VOL}:/ripc" -v "${RUN}:/usr/local/bin/anyreal-run:ro" \
        -e ANYREAL_DEBUG=1 \
        "${CEOS_ENV[@]}" "${IMG}" \
        /usr/local/bin/anyreal-run --supervise-self --node "${id}" --peers "${peers}" \
        --real --ripc /ripc --mng /ripc/msg_manager_socket -- \
        /sbin/init systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" \
        systemd.setenv="container=docker" systemd.setenv="ETBA=1" \
        systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" \
        systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0" >/dev/null
}

echo "-- starting cEOS under AnyREAL broker --"
start_node "${N1}" 1 "${IP1}" "${IP1}:${IP2}:2;"
start_node "${N2}" 2 "${IP2}" "${IP2}:${IP1}:1;"

echo "-- waiting for CLIs (broker boot may be slower) --"
for n in "${N1}" "${N2}"; do
    ok=0
    for _ in $(seq 1 90); do
        clic "${n}" "show version" | grep -q cEOSLab && { ok=1; break; }
        sleep 2
    done
    [ "${ok}" = 1 ] || { echo "FAILED: ${n} CLI not ready"; docker logs "${n}" 2>&1 | tail -20; exit 1; }
done
echo "both CLIs ready"

echo "-- starting controller --"
docker run -d --name "${CTRL}" -v "${VOL}:${RIPC}" -v "${ROOT}:/work" \
    -w /work/third_party/REAL -e ANYREAL_CONVERGE_SEC=600 "${UBUNTU}" \
    bash -c "ln -sfn /opt/lwc/volumes/ripc /ripc; mkdir -p /tmp/res/ctrl; exec ./controller/controller ceos topo2 /tmp/res \"\$(nproc)\" 900 hosts.json" >/dev/null
for _ in $(seq 1 30); do docker exec "${CTRL}" bash -lc "test -S ${RIPC}/msg_manager_socket" 2>/dev/null && break; sleep 1; done

echo "-- configuring BGP --"
cli "${N1}" "configure\nip routing\ninterface Management0\nip address ${IP1}/24\nno shutdown\nexit\nrouter bgp 65001\nrouter-id 1.1.1.1\nneighbor ${IP2} remote-as 65002\nexit\nend\nwrite\n"
cli "${N2}" "configure\nip routing\ninterface Management0\nip address ${IP2}/24\nno shutdown\nexit\nrouter bgp 65002\nrouter-id 2.2.2.2\nneighbor ${IP1} remote-as 65001\nexit\nend\nwrite\n"

echo "-- waiting for Established --"
ok=0
for _ in $(seq 1 90); do
    if clic "${N1}" "show ip bgp summary" | grep -qE "${IP2}.*Estab" && clic "${N2}" "show ip bgp summary" | grep -qE "${IP1}.*Estab"; then ok=1; break; fi
    sleep 2
done
clic "${N1}" "show ip bgp summary" | tee "${LOGDIR}/n1-summary.txt"
clic "${N2}" "show ip bgp summary" | tee "${LOGDIR}/n2-summary.txt"
[ "${ok}" = 1 ] || { echo "FAILED: session not established"; docker logs "${CTRL}" 2>&1 | tail -10; exit 1; }
echo "session Established (broker path)"

echo "-- advertise/withdraw --"
cli "${N1}" "configure\nip route 192.168.1.0/24 Null0\nrouter bgp 65001\nnetwork 192.168.1.0/24\nexit\nend\nwrite\n"
found=0; for _ in $(seq 1 40); do clic "${N2}" "show ip bgp" | grep -q '192.168.1.0/24' && { found=1; break; }; sleep 2; done
[ "${found}" = 1 ] || { echo "FAILED: prefix not propagated"; exit 1; }
cli "${N1}" "configure\nrouter bgp 65001\nno network 192.168.1.0/24\nexit\nend\nwrite\n"
gone=0; for _ in $(seq 1 60); do clic "${N2}" "show ip bgp" | grep -q '192.168.1.0/24' || { gone=1; break; }; sleep 2; done
[ "${gone}" = 1 ] || { echo "FAILED: prefix not withdrawn"; exit 1; }

echo "B_CEOS_PASS (logs in ${LOGDIR})"
