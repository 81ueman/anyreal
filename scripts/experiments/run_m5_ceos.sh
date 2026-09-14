#!/usr/bin/env bash
# M5: run two ARM64 cEOS-lab nodes (containerlab-equivalent settings) in Docker
# and establish an eBGP session over a shared bridge. This is the *baseline*
# (no AnyREAL) needed before M6.
#
# Node CLI is `Cli` (= /usr/bin/FastCli). Each node gets its own flash volume.
set -euo pipefail

C1="${C1:-anyreal-ceos1}"
C2="${C2:-anyreal-ceos2}"
NET="${NET:-anyreal-ceoslab}"
SUBNET="${SUBNET:-10.10.0.0/24}"
IP1="${IP1:-10.10.0.2}"
IP2="${IP2:-10.10.0.3}"
IMAGE="${IMAGE:-ceos:4.36.0.1F}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGDIR="${ROOT}/.scratch/m5/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${LOGDIR}"

CEOS_ENV=(
  -e CEOS=1 -e EOS_PLATFORM=ceoslab -e container=docker -e ETBA=1
  -e SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1 -e INTFTYPE=eth -e MAPETH0=1 -e MGMT_INTF=eth0
)
CEOS_INIT='exec /sbin/init systemd.setenv="CEOS=1" systemd.setenv="EOS_PLATFORM=ceoslab" systemd.setenv="container=docker" systemd.setenv="ETBA=1" systemd.setenv="SKIP_ZEROTOUCH_BARRIER_IN_SYSDBINIT=1" systemd.setenv="INTFTYPE=eth" systemd.setenv="MAPETH0=1" systemd.setenv="MGMT_INTF=eth0"'

cleanup() {
    set +e
    docker rm -f "${C1}" "${C2}" >/dev/null 2>&1
    docker network rm "${NET}" >/dev/null 2>&1
}
trap cleanup EXIT

cleanup
docker network create --subnet "${SUBNET}" "${NET}" >/dev/null

start_node() {
    local name="$1" ip="$2"
    docker run -d --name "${name}" --privileged --network "${NET}" --ip "${ip}" \
        "${CEOS_ENV[@]}" "${IMAGE}" bash -c "${CEOS_INIT}" >/dev/null
}

cli() { docker exec "$1" bash -lc "printf '$2' | timeout 60 FastCli -p 15"; }
cli_c() { docker exec "$1" bash -lc "timeout 25 Cli -p 15 -c \"$2\""; }

wait_cli() {
    local name="$1"
    for _ in $(seq 1 60); do
        if docker exec "${name}" bash -lc 'test -x /usr/bin/Cli' 2>/dev/null \
           && cli_c "${name}" "show version" 2>/dev/null | grep -q cEOSLab; then
            return 0
        fi
        sleep 2
    done
    echo "FAILED: ${name} CLI not ready" >&2
    return 1
}

echo "-- starting cEOS nodes --"
start_node "${C1}" "${IP1}"
start_node "${C2}" "${IP2}"
wait_cli "${C1}"
wait_cli "${C2}"
echo "both CLIs ready"
echo "-- settling --"
sleep 20

echo "-- configuring BGP --"
cli "${C1}" "configure\nip routing\ninterface Management0\nip address ${IP1}/24\nno shutdown\nexit\nrouter bgp 65001\nrouter-id 1.1.1.1\nneighbor ${IP2} remote-as 65002\nexit\nend\nwrite\n" >"${LOGDIR}/c1-config.log" 2>&1 || true
cli "${C2}" "configure\nip routing\ninterface Management0\nip address ${IP2}/24\nno shutdown\nexit\nrouter bgp 65002\nrouter-id 2.2.2.2\nneighbor ${IP1} remote-as 65001\nexit\nend\nwrite\n" >"${LOGDIR}/c2-config.log" 2>&1 || true

echo "-- waiting for session --"
ok=0
for _ in $(seq 1 40); do
    if cli_c "${C1}" "show ip bgp summary" 2>/dev/null | grep -qE "${IP2}.*Estab" \
       && cli_c "${C2}" "show ip bgp summary" 2>/dev/null | grep -qE "${IP1}.*Estab"; then
        ok=1; break
    fi
    sleep 2
done
cli_c "${C1}" "show ip bgp summary" | tee "${LOGDIR}/c1-summary.txt"
cli_c "${C2}" "show ip bgp summary" | tee "${LOGDIR}/c2-summary.txt"
if [ "${ok}" != 1 ]; then
    echo "FAILED: session not Established"
    echo "--- c1 config ---"; cat "${LOGDIR}/c1-config.log"
    echo "--- c2 config ---"; cat "${LOGDIR}/c2-config.log"
    exit 1
fi
echo "session Established"

echo "-- advertise 192.168.1.0/24 from c1 --"
cli "${C1}" "configure\nip route 192.168.1.0/24 Null0\nrouter bgp 65001\nnetwork 192.168.1.0/24\nexit\nend\nwrite\n" >/dev/null 2>&1 || true
sleep 5
cli_c "${C2}" "show ip bgp" | tee "${LOGDIR}/c2-rib.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/c2-rib.txt" || { echo "FAILED: prefix not propagated"; exit 1; }

echo "-- withdraw --"
cli "${C1}" "configure\nrouter bgp 65001\nno network 192.168.1.0/24\nexit\nend\nwrite\n" >/dev/null 2>&1 || true
sleep 5
cli_c "${C2}" "show ip bgp" | tee "${LOGDIR}/c2-rib.after.txt"
grep -q '192.168.1.0/24' "${LOGDIR}/c2-rib.after.txt" && { echo "FAILED: prefix not withdrawn"; exit 1; }

echo "M5_CEOS_PASS (logs in ${LOGDIR})"
