#!/usr/bin/env bash
# Generalized cEOS x REAL-controller harness for N nodes (line topology).
#
#   scripts/experiments/run_ceos_topo.sh N
#
# Node i (1..N): ip 10.70.0.<10+i>, AS 65000+i, neighbors i-1 and i+1.
# Verifies: all sessions Established; a prefix advertised at node1 reaches nodeN.
#
# Memory note: starts all N cEOS containers at once; keep N small (<=4) or run
# one topology at a time and let the EXIT trap clean up.
set -euo pipefail

N="${1:-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NET="anyreal-topo-net"
VOL="anyreal-topo-ripc"
SUBNET="10.70.0.0/24"
CTRL="anyreal-topo-ctrl"
IMG="${IMG:-ceos:4.36.0.1F}"
UBUNTU="${UBUNTU:-ubuntu:24.04}"
RIPC="/opt/lwc/volumes/ripc"
TOPO="topo${N}"
LOGDIR="${ROOT}/.scratch/topo${N}/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOGDIR}"

ip_of() { echo "10.70.0.$((10 + $1))"; }
as_of() { echo "$((65000 + $1))"; }
cname() { echo "anyreal-n$1"; }

CEOS_ENV=(-e CEOS=1 -e EOS_PLATFORM=ceoslab -e container=docker -e ETBA=1
  -e SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1 -e INTFTYPE=eth -e MAPETH0=1 -e MGMT_INTF=eth0)
CEOS_INIT='exec /sbin/init systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" systemd.setenv="container=docker" systemd.setenv="ETBA=1" systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0"'

cleanup() {
    set +e
    for i in $(seq 1 "${N}"); do docker rm -f "$(cname "$i")" >/dev/null 2>&1; done
    docker rm -f "${CTRL}" >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
    docker volume rm "${VOL}" >/dev/null 2>&1
}
on_exit() { [ "${KEEP:-0}" = "1" ] || cleanup; }
trap on_exit EXIT

cli()  { docker exec "$1" bash -lc "printf '$2' | timeout 60 FastCli -p 15" >/dev/null 2>&1 || true; }
clic() { docker exec "$1" bash -lc "timeout 25 Cli -p 15 -c \"$2\" 2>/dev/null"; }

cleanup
docker network create --subnet "${SUBNET}" "${NET}" >/dev/null
docker volume create "${VOL}" >/dev/null

echo "-- generating blueprint (${TOPO}, N=${N}, line) --"
mkdir -p "${ROOT}/third_party/REAL/conf/ceos/${TOPO}"
python3 - "$N" "$TOPO" "${ROOT}/third_party/REAL/conf/ceos" <<'PY'
import json, sys
n = int(sys.argv[1]); topo = sys.argv[2]; base = sys.argv[3]
routers = []
for i in range(1, n + 1):
    neigh = []
    for j in (i - 1, i + 1):
        if 1 <= j <= n:
            neigh.append({"self_ip": f"10.70.0.{10+i}", "neighbor_ip": f"10.70.0.{10+j}", "peeridx": j})
    routers.append({"idx": i, "neighbors": neigh})
with open(f"{base}/{topo}/blueprint.json", "w") as f:
    json.dump({"routers": routers}, f, indent=2)
print("wrote", f"{base}/{topo}/blueprint.json")
PY
printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/third_party/REAL/hosts.json"

echo "-- starting ${N} cEOS nodes --"
for i in $(seq 1 "${N}"); do
    docker run -d --name "$(cname "$i")" --privileged --network "${NET}" --ip "$(ip_of "$i")" \
        -v "${VOL}:/ripc" "${CEOS_ENV[@]}" "${IMG}" bash -c "${CEOS_INIT}" >/dev/null
done

echo "-- waiting for CLIs --"
for i in $(seq 1 "${N}"); do
    ok=0
    for _ in $(seq 1 60); do
        if clic "$(cname "$i")" "show version" | grep -q cEOSLab; then ok=1; break; fi
        sleep 2
    done
    [ "${ok}" = 1 ] || { echo "FAILED: node $i CLI not ready"; exit 1; }
done
echo "all CLIs ready"

echo "-- injecting preload (Bgp only) --"
for i in $(seq 1 "${N}"); do
    name="$(cname "$i")"
    peerlist=""
    for j in $(seq 1 "${N}"); do
        if [ "$j" != "$i" ] && { [ "$j" = "$((i-1))" ] || [ "$j" = "$((i+1))" ]; }; then
            peerlist="${peerlist}$(ip_of "$i"):$(ip_of "$j"):${j},"
        fi
    done
    docker cp "${ROOT}/third_party/REAL/preload/libpreload.so" "${name}:/usr/lib/libpreload.so"
    docker exec "${name}" bash -lc "
        mkdir -p /ripc/emu-real-${i}
        printf 'NODE_ID=${i}\nPEER_LIST=${peerlist}\nBASE_TS=0\nRT_BASE_TS=0\nMONO_RAW_BASE_TS=0\n' > /real_env
        if [ ! -e /usr/bin/Bgp.real ]; then mv /usr/bin/Bgp /usr/bin/Bgp.real; fi
        printf '#!/bin/bash\nexport LD_PRELOAD=/usr/lib/libpreload.so\nexec -a Bgp /usr/bin/Bgp.real \"\$@\"\n' > /usr/bin/Bgp
        chmod 755 /usr/bin/Bgp
    " >"${LOGDIR}/inject-${i}.log" 2>&1
done

echo "-- starting REAL controller (${TOPO}) --"
docker run -d --name "${CTRL}" -v "${VOL}:${RIPC}" -v "${ROOT}:/work" \
    -w /work/third_party/REAL -e ANYREAL_CONVERGE_SEC=600 "${UBUNTU}" \
    bash -c "ln -sfn /opt/lwc/volumes/ripc /ripc; mkdir -p /tmp/res/ctrl; exec ./controller/controller ceos ${TOPO} /tmp/res \"\$(nproc)\" 900 hosts.json" >/dev/null
for _ in $(seq 1 30); do
    docker exec "${CTRL}" bash -lc "test -S ${RIPC}/msg_manager_socket" 2>/dev/null && break
    sleep 1
done

echo "-- configuring BGP --"
for i in $(seq 1 "${N}"); do
    cfg="configure\nip routing\ninterface Management0\nip address $(ip_of "$i")/24\nno shutdown\nexit\nrouter bgp $(as_of "$i")\nrouter-id 1.1.1.${i}\n"
    for j in $(seq 1 "${N}"); do
        if [ "$j" != "$i" ] && { [ "$j" = "$((i-1))" ] || [ "$j" = "$((i+1))" ]; }; then
            cfg="${cfg}neighbor $(ip_of "$j") remote-as $(as_of "$j")\n"
        fi
    done
    cfg="${cfg}exit\nend\nwrite\n"
    cli "$(cname "$i")" "$cfg" >"${LOGDIR}/cfg-${i}.log" 2>&1 || true
done

echo "-- waiting for all sessions Established --"
estab=0
for _ in $(seq 1 90); do
    all=1
    for i in $(seq 1 "${N}"); do
        for j in $(seq 1 "${N}"); do
            if [ "$j" != "$i" ] && { [ "$j" = "$((i-1))" ] || [ "$j" = "$((i+1))" ]; }; then
                clic "$(cname "$i")" "show ip bgp summary" | grep -qE "$(ip_of "$j").*Estab" || all=0
            fi
        done
    done
    if [ "${all}" = 1 ]; then estab=1; break; fi
    sleep 2
done
for i in $(seq 1 "${N}"); do clic "$(cname "$i")" "show ip bgp summary" > "${LOGDIR}/summary-${i}.txt"; done
if [ "${estab}" != 1 ]; then
    echo "FAILED: not all sessions Established"
    tail -20 "${LOGDIR}"/summary-*.txt 2>/dev/null || true
    exit 1
fi
echo "all sessions Established"

echo "-- advertise 192.168.1.0/24 from node1 --"
cli "$(cname 1)" "configure\nip route 192.168.1.0/24 Null0\nrouter bgp $(as_of 1)\nnetwork 192.168.1.0/24\nexit\nend\nwrite\n"
found=0
for _ in $(seq 1 40); do
    clic "$(cname "${N}")" "show ip bgp" | grep -q '192.168.1.0/24' && { found=1; break; }
    sleep 2
done
clic "$(cname "${N}")" "show ip bgp" | tee "${LOGDIR}/node${N}-rib.txt"
[ "${found}" = 1 ] || { echo "FAILED: prefix not propagated to node${N}"; exit 1; }
echo "prefix reached node${N}"

echo "-- withdraw --"
cli "$(cname 1)" "configure\nrouter bgp $(as_of 1)\nno network 192.168.1.0/24\nexit\nend\nwrite\n"
gone=0
for _ in $(seq 1 90); do
    clic "$(cname "${N}")" "show ip bgp" | grep -q '192.168.1.0/24' || { gone=1; break; }
    sleep 2
done
clic "$(cname "${N}")" "show ip bgp" | tee "${LOGDIR}/node${N}-rib.after.txt"
[ "${gone}" = 1 ] || { echo "FAILED: prefix not withdrawn"; exit 1; }

echo "M6_TOPO${N}_PASS (logs in ${LOGDIR})"
