#!/usr/bin/env bash
# Mixed 4-node PoC: GoBGP (broker/seccomp) + cEOS (preload), all through one
# REAL controller. Line topology:
#   node1 GoBGP(65001,10.72.0.11) - node2 cEOS(65002,.12)
#   - node3 GoBGP(65003,.13) - node4 cEOS(65004,.14)
#
# Prereqs:
#   build/anyreal-run                 (Ubuntu build, dev container)
#   build/gobgpd, build/gobgp         (GoBGP arm64)
#   third_party/REAL/preload/libpreload.so  (almalinux:9, IMAGE_CEOS=1)
#   third_party/REAL/controller/controller  (R2I/TWO_PHASE disabled)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NET="anyreal-mix-net"; VOL="anyreal-mix-ripc"; SUBNET="10.72.0.0/24"
CTRL="anyreal-mix-ctrl"; IMG="${IMG:-ceos:4.36.0.1F}"; UBUNTU="${UBUNTU:-ubuntu:24.04}"
RIPC="/opt/lwc/volumes/ripc"
LOGDIR="${ROOT}/.scratch/mixed/$(date +%Y%m%d_%H%M%S)"; mkdir -p "${LOGDIR}"

declare -a NAME IP AS
NAME[1]=anyreal-mix1; IP[1]=10.72.0.11; AS[1]=65001
NAME[2]=anyreal-mix2; IP[2]=10.72.0.12; AS[2]=65002
NAME[3]=anyreal-mix3; IP[3]=10.72.0.13; AS[3]=65003
NAME[4]=anyreal-mix4; IP[4]=10.72.0.14; AS[4]=65004
# kind: 1=GoBGP(broker), 2=cEOS(preload)

CEOS_ENV=(-e CEOS=1 -e EOS_PLATFORM=ceoslab -e container=docker -e ETBA=1
  -e SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1 -e INTFTYPE=eth -e MAPETH0=1 -e MGMT_INTF=eth0)
CEOS_INIT='exec /sbin/init systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" systemd.setenv="container=docker" systemd.setenv="ETBA=1" systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0"'

cleanup() { set +e; for i in 1 2 3 4; do docker rm -f "${NAME[$i]}" >/dev/null 2>&1; done; docker rm -f "${CTRL}" >/dev/null 2>&1; docker network rm "${NET}" >/dev/null 2>&1; docker volume rm "${VOL}" >/dev/null 2>&1; }
on_exit() { [ "${KEEP:-0}" = "1" ] || cleanup; }
trap on_exit EXIT

ceos_cli() { docker exec "$1" bash -lc "printf '$2' | timeout 60 FastCli -p 15" >/dev/null 2>&1 || true; }
ceos_show() { docker exec "$1" bash -lc "timeout 25 Cli -p 15 -c \"$2\" 2>/dev/null"; }
gobgp_cli() { docker exec "$1" bash -lc "/work/build/gobgp -p 5005$2 ${3:-}" 2>/dev/null; }

cleanup
docker network create --subnet "${SUBNET}" "${NET}" >/dev/null
docker volume create "${VOL}" >/dev/null

echo "-- blueprint --"
mkdir -p "${ROOT}/third_party/REAL/conf/ceos/mixed4"
python3 - "${ROOT}/third_party/REAL/conf/ceos/mixed4" <<'PY'
import json, sys
base = sys.argv[1]
ip = {1:"10.72.0.11",2:"10.72.0.12",3:"10.72.0.13",4:"10.72.0.14"}
edges = {1:[2],2:[1,3],3:[2,4],4:[3]}
r = [{"idx":i, "neighbors":[{"self_ip":ip[i], "neighbor_ip":ip[j], "peeridx":j} for j in edges[i]]} for i in range(1,5)]
json.dump({"routers": r}, open(base + "/blueprint.json", "w"), indent=2)
PY
printf '{"hosts":[{"id":0,"ip":"0.0.0.0","port":0}],"self_id":0}' > "${ROOT}/third_party/REAL/hosts.json"

echo "-- starting cEOS nodes (2,4) with preload --"
for i in 2 4; do
    docker run -d --name "${NAME[$i]}" --privileged --network "${NET}" --ip "${IP[$i]}" \
        -v "${VOL}:/ripc" "${CEOS_ENV[@]}" "${IMG}" bash -c "${CEOS_INIT}" >/dev/null
done

echo "-- starting GoBGP nodes (1,3) under broker --"
peers_for() { case "$1" in 1) echo "10.72.0.11:10.72.0.12:2;";; 3) echo "10.72.0.13:10.72.0.12:2;10.72.0.13:10.72.0.14:4;";; esac; }
for i in 1 3; do
    peers="$(peers_for "$i")"
    cmd="exec /usr/local/bin/anyreal-run --node ${i} --peers \"${peers}\" --real --ripc /ripc --mng /ripc/msg_manager_socket -- /work/build/gobgpd -f /work/tests/mixed/node${i}.toml -l info --api-hosts 127.0.0.1:5005${i} --pprof-host 127.0.0.1:606${i}"
    docker run -d --name "${NAME[$i]}" --privileged --network "${NET}" --ip "${IP[$i]}" \
        -v "${VOL}:/ripc" -v "${ROOT}:/work" -v "${ROOT}/build/anyreal-run:/usr/local/bin/anyreal-run:ro" \
        "${UBUNTU}" bash -c "${cmd}" >/dev/null
done

echo "-- waiting for cEOS CLIs and GoBGP gRPC --"
for i in 2 4; do
    ok=0; for _ in $(seq 1 60); do ceos_show "${NAME[$i]}" "show version" | grep -q cEOSLab && { ok=1; break; }; sleep 2; done
    [ "$ok" = 1 ] || { echo "FAILED: ${NAME[$i]} CLI"; exit 1; }
done
for i in 1 3; do
    ok=0; for _ in $(seq 1 60); do docker exec "${NAME[$i]}" bash -lc "/work/build/gobgp -p 5005${i} neighbor" 2>/dev/null | grep -q . && { ok=1; break; }; sleep 2; done
    [ "$ok" = 1 ] || { echo "FAILED: GoBGP ${i} gRPC"; docker logs "${NAME[$i]}" 2>&1 | tail -10; exit 1; }
done

echo "-- injecting cEOS preload --"
for i in 2 4; do
    peers=""
    case $i in
      2) peers="${IP[2]}:${IP[1]}:1,${IP[2]}:${IP[3]}:3,";;
      4) peers="${IP[4]}:${IP[3]}:3,";;
    esac
    docker cp "${ROOT}/third_party/REAL/preload/libpreload.so" "${NAME[$i]}:/usr/lib/libpreload.so"
    docker exec "${NAME[$i]}" bash -lc "
        mkdir -p /ripc/emu-real-${i}
        printf 'NODE_ID=${i}\nPEER_LIST=${peers}\nBASE_TS=0\nRT_BASE_TS=0\nMONO_RAW_BASE_TS=0\n' > /real_env
        if [ ! -e /usr/bin/Bgp.real ]; then mv /usr/bin/Bgp /usr/bin/Bgp.real; fi
        printf '#!/bin/bash\nexport LD_PRELOAD=/usr/lib/libpreload.so\nexec -a Bgp /usr/bin/Bgp.real \"\$@\"\n' > /usr/bin/Bgp; chmod 755 /usr/bin/Bgp
        mkdir -p /ripc/emu-real-1 /ripc/emu-real-3
    " >/dev/null 2>&1
done

echo "-- controller --"
docker run -d --name "${CTRL}" -v "${VOL}:${RIPC}" -v "${ROOT}:/work" \
    -w /work/third_party/REAL -e ANYREAL_CONVERGE_SEC=600 "${UBUNTU}" \
    bash -c "ln -sfn /opt/lwc/volumes/ripc /ripc; mkdir -p /tmp/res/ctrl; exec ./controller/controller ceos mixed4 /tmp/res \"\$(nproc)\" 900 hosts.json" >/dev/null
for _ in $(seq 1 30); do docker exec "${CTRL}" bash -lc "test -S ${RIPC}/msg_manager_socket" 2>/dev/null && break; sleep 1; done

echo "-- configuring cEOS BGP (2,4) --"
ceos_cli "${NAME[2]}" "configure\nip routing\ninterface Management0\nip address ${IP[2]}/24\nno shutdown\nexit\nrouter bgp ${AS[2]}\nrouter-id 2.2.2.2\nneighbor ${IP[1]} remote-as ${AS[1]}\nneighbor ${IP[3]} remote-as ${AS[3]}\nexit\nend\nwrite\n"
ceos_cli "${NAME[4]}" "configure\nip routing\ninterface Management0\nip address ${IP[4]}/24\nno shutdown\nexit\nrouter bgp ${AS[4]}\nrouter-id 4.4.4.4\nneighbor ${IP[3]} remote-as ${AS[3]}\nexit\nend\nwrite\n"

echo "-- waiting for all adjacencies Established --"
ok=0
for _ in $(seq 1 90); do
    all=1
    docker exec "${NAME[1]}" bash -lc "/work/build/gobgp -p 50051 neighbor" | grep -qE "${IP[2]}.*Establ" || all=0
    docker exec "${NAME[3]}" bash -lc "/work/build/gobgp -p 50053 neighbor" | grep -qE "${IP[2]}.*Establ" || all=0
    docker exec "${NAME[3]}" bash -lc "/work/build/gobgp -p 50053 neighbor" | grep -qE "${IP[4]}.*Establ" || all=0
    ceos_show "${NAME[2]}" "show ip bgp summary" | grep -qE "${IP[1]}.*Estab" || all=0
    ceos_show "${NAME[2]}" "show ip bgp summary" | grep -qE "${IP[3]}.*Estab" || all=0
    ceos_show "${NAME[4]}" "show ip bgp summary" | grep -qE "${IP[3]}.*Estab" || all=0
    [ "$all" = 1 ] && { ok=1; break; }
    sleep 2
done
if [ "$ok" != 1 ]; then
    echo "FAILED: not all adjacencies Established"
    for i in 1 3; do echo "-- GoBGP $i"; docker exec "${NAME[$i]}" bash -lc "/work/build/gobgp -p 5005$i neighbor" 2>/dev/null; done
    for i in 2 4; do echo "-- cEOS $i"; ceos_show "${NAME[$i]}" "show ip bgp summary"; done
    exit 1
fi
echo "all adjacencies Established (GoBGP + cEOS mixed)"

echo "-- advertise 192.168.1.0/24 from node1 (GoBGP) --"
docker exec "${NAME[1]}" bash -lc "/work/build/gobgp -p 50051 global rib add 192.168.1.0/24"
found=0
for _ in $(seq 1 45); do ceos_show "${NAME[4]}" "show ip bgp" | grep -q '192.168.1.0/24' && { found=1; break; }; sleep 2; done
ceos_show "${NAME[4]}" "show ip bgp" | tee "${LOGDIR}/node4(ceos)-rib.txt"
[ "$found" = 1 ] || { echo "FAILED: prefix not propagated to node4"; exit 1; }
echo "prefix reached node4 (cEOS) via GoBGP->cEOS->GoBGP->cEOS"

echo "-- withdraw --"
docker exec "${NAME[1]}" bash -lc "/work/build/gobgp -p 50051 global rib del 192.168.1.0/24"
gone=0
for _ in $(seq 1 45); do ceos_show "${NAME[4]}" "show ip bgp" | grep -q '192.168.1.0/24' || { gone=1; break; }; sleep 2; done
[ "$gone" = 1 ] || { echo "FAILED: prefix not withdrawn"; exit 1; }

echo "MIXED4_PASS (logs in ${LOGDIR})"
