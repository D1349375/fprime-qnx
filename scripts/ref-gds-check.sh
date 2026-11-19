#!/usr/bin/env bash
####
# ref-gds-check.sh: end-to-end check that the adopted Ref deployment runs on QNX and talks to the F Prime GDS.
#
#   1. boots the mkqnximage QEMU/KVM guest (headless) if it is not running
#   2. starts fprime-gds on the host as the TCP server (no GUI)
#   3. copies Ref to the guest and starts it as the TCP client
#   4. sends CdhCore.cmdDisp.CMD_NO_OP and checks the GDS event log for the completion event
#   5. checks the GDS telemetry log for periodic rate-group telemetry
#
# Environment: QNX_IMAGE_DIR (default ~/qnx/images/smoke), QNX_SSH_KEY (default ~/.ssh/qnx_vm),
#              GDS_PORT (default 50000), CHECK_SECONDS (default 20). Requires the qnx-x86_64 build to exist.
# Output: run directory under adoption/logs/ref-gds-check-<timestamp> with the GDS logs and the target console log.
####
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${ROOT}/adoption/build-artifacts/qnx-x86_64/Ref"
DICT="${ART}/dict/RefTopologyDictionary.json"
BIN="${ART}/bin/Ref"
IMAGE_DIR="${QNX_IMAGE_DIR:-${HOME}/qnx/images/smoke}"
KEY="${QNX_SSH_KEY:-${HOME}/.ssh/qnx_vm}"
PORT="${GDS_PORT:-50000}"
CHECK_SECONDS="${CHECK_SECONDS:-20}"
RUN_DIR="${ROOT}/adoption/logs/ref-gds-check-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${RUN_DIR}"

SSH_OPTS=(-i "${KEY}" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts_qnx"
          -o ConnectTimeout=5 -o BatchMode=yes)
GDS_PID=""
GUEST=""

log() { echo "[ref-gds-check] $*"; }
fail() { log "FAIL: $*"; exit 1; }

cleanup() {
    if [ -n "${GUEST}" ]; then
        ssh "${SSH_OPTS[@]}" "root@${GUEST}" 'slay -f Ref >/dev/null 2>&1; cat /tmp/fprime-ref/ref.log 2>/dev/null' \
            > "${RUN_DIR}/target-console.log" 2>/dev/null
    fi
    if [ -n "${GDS_PID}" ]; then
        kill "${GDS_PID}" >/dev/null 2>&1
        wait "${GDS_PID}" 2>/dev/null
    fi
}
trap cleanup EXIT

[ -x "${BIN}" ] || fail "missing ${BIN}; build with: fprime-util build qnx-x86_64 (in adoption/)"
[ -n "${QNX_HOST:-}" ] || fail "QNX environment not set; run: source <sdp>/qnxsdp-env.sh"
command -v fprime-gds >/dev/null || fail "fprime-gds not on PATH; activate the F Prime venv"

# 1. Guest
cd "${IMAGE_DIR}" || fail "image directory ${IMAGE_DIR} not found"
if ! pgrep -f "qemu-system-x86_64.*${IMAGE_DIR}|qemu-system-x86_64.*disk-qemu.vmdk" >/dev/null; then
    log "booting QNX guest from ${IMAGE_DIR}"
    # Do not pipe this: the backgrounded QEMU inherits stderr and would hold the pipe open.
    # setsid keeps QEMU out of this shell's session so it survives SIGHUP when the WSL session closes.
    setsid mkqnximage --run=-h > "${RUN_DIR}/vm-boot.log" 2>&1 < /dev/null
fi
for _ in $(seq 1 60); do
    # mkqnximage --getip needs arp (net-tools); fall back to the libvirt DHCP lease for this MAC
    GUEST="$(mkqnximage --getip 2>/dev/null | grep -Eo '([0-9]+\.){3}[0-9]+' | tail -1)"
    if [ -z "${GUEST}" ]; then
        MAC="$(grep -o 'OPT_MACADDR=.*' output/options 2>/dev/null | cut -d"'" -f2)"
        GUEST="$(virsh -c qemu:///system net-dhcp-leases default 2>/dev/null | grep -i "${MAC:-52:54}" \
                 | grep -Eo '([0-9]+\.){3}[0-9]+' | tail -1)"
    fi
    if [ -n "${GUEST}" ] && ssh "${SSH_OPTS[@]}" "root@${GUEST}" true 2>/dev/null; then
        break
    fi
    GUEST=""
    sleep 2
done
[ -n "${GUEST}" ] || fail "guest did not become reachable over SSH"
HOST_IP="$(ip -4 -o addr show virbr0 | awk '{print $4}' | cut -d/ -f1)"
log "guest ${GUEST}, host bridge ${HOST_IP}"
ssh "${SSH_OPTS[@]}" "root@${GUEST}" 'uname -a' | tee "${RUN_DIR}/target-uname.txt"

# 2. GDS (TCP server, no GUI)
log "starting fprime-gds on 0.0.0.0:${PORT}"
fprime-gds -n -g none --dictionary "${DICT}" --framing-selection space-packet-space-data-link \
    --ip-address 0.0.0.0 --ip-port "${PORT}" -l "${RUN_DIR}/gds" --log-directly \
    > "${RUN_DIR}/gds-stdout.log" 2>&1 < /dev/null &
GDS_PID=$!
sleep 5
kill -0 "${GDS_PID}" 2>/dev/null || fail "fprime-gds exited early; see ${RUN_DIR}/gds-stdout.log"

# 3. Ref on the target
log "deploying Ref to the guest"
ssh "${SSH_OPTS[@]}" "root@${GUEST}" 'slay -f Ref >/dev/null 2>&1; mkdir -p /tmp/fprime-ref'
scp -q "${SSH_OPTS[@]}" "${BIN}" "root@${GUEST}:/tmp/fprime-ref/Ref" || fail "scp to guest failed"
# -f: the QNX shell keeps the channel open for its background job, so let ssh go to the background after auth
ssh -n -f "${SSH_OPTS[@]}" "root@${GUEST}" \
    "cd /tmp/fprime-ref && nohup ./Ref -a ${HOST_IP} -p ${PORT} > ref.log 2>&1 < /dev/null &"
sleep 8

# 4. Command round trip. With `-g none` the GDS itself writes no Event/Channel logs, so the downlink is observed with
#    fprime-cli listeners started before the command is sent. Each listener returns on its first matching item, so
#    there is one listener per expected event or channel.
LISTEN_SECONDS=$((CHECK_SECONDS + 5))
LISTENER_PIDS=()
listen() {  # listen <events|channels> <search> <name>
    fprime-cli "$1" --dictionary "${DICT}" -s "$2" -t "${LISTEN_SECONDS}" -l "${RUN_DIR}/cli-$3" --log-directly \
        > "${RUN_DIR}/downlink-$3.txt" 2>&1 &
    LISTENER_PIDS+=($!)
}
listen events NoOpReceived event-noop
listen events OpCodeCompleted event-completed
listen channels rateGroup1Comp channel-rategroup1
sleep 3
log "sending CdhCore.cmdDisp.CMD_NO_OP"
fprime-cli command-send CdhCore.cmdDisp.CMD_NO_OP --dictionary "${DICT}" -l "${RUN_DIR}/cli-command" --log-directly \
    > "${RUN_DIR}/cli-command.log" 2>&1
wait "${LISTENER_PIDS[@]}" 2>/dev/null

# 5. Verdict
RESULT=0
check() {  # check <name> <pattern> <description>
    local file="${RUN_DIR}/downlink-$1.txt"
    if grep -q "$2" "${file}" 2>/dev/null; then
        log "PASS: $3"
        grep "$2" "${file}" | head -1
    else
        log "FAIL: $3 (nothing matching '$2' in ${file})"
        RESULT=1
    fi
}
check event-noop "cmdDisp.NoOpReceived" "NoOpReceived event downlinked from target"
check event-completed "cmdDisp.OpCodeCompleted" "OpCodeCompleted event downlinked from target"
check channel-rategroup1 "rateGroup1Comp" "rate group 1 telemetry downlinked from target"
log "logs: ${RUN_DIR}"
exit "${RESULT}"
