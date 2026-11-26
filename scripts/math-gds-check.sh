#!/usr/bin/env bash
####
# math-gds-check.sh: end-to-end check that the adopted MathComponent tutorial deployment runs on QNX with F Prime GDS.
#
#   1. builds a fresh mkqnximage QEMU/KVM guest (or uses QNX_IMAGE_DIR) and boots it headless
#   2. starts fprime-gds on the host as the TCP server with private ZMQ endpoints and records the decoded downlink
#   3. copies MathDeployment to the guest and starts it as the TCP client
#   4. sends CMD_NO_OP, mathSender.DO_MATH, the mathReceiver FACTOR parameter and a division by zero, and checks the
#      events and telemetry for each. MathReceiver is a queued component: rate group 1, driven by Svc.QnxTimer,
#      dispatches its operation queue, so every result passes through the QNX timer path.
#   5. stops the deployment with SIGTERM, which calls Svc.QnxTimer quit(), and checks for an orderly exit
#
# Run scripts/import-math.sh and build adoption/math-tutorial for qnx-x86_64 first.
# Environment: QNX_IMAGE_DIR and QNX_SSH_KEY to reuse a guest image, GDS_PORT (default: an unused port),
#              GDS_EVIDENCE_ROOT (default: TMPDIR or /tmp; must be outside the repository).
####
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/qnx-vm.sh"
[[ $# -eq 0 ]] || { echo 'Usage: scripts/math-gds-check.sh' >&2; exit 2; }

: "${QNX_TARGET:?Source the QNX SDP environment first}"
artifacts=$root/adoption/math-tutorial/build-artifacts/qnx-x86_64/MathProject_MathDeployment
binary=$artifacts/bin/MathProject_MathDeployment
dictionary=$artifacts/dict/MathDeploymentTopologyDictionary.json
[[ -x "$binary" && -r "$dictionary" ]] || {
    echo 'Run scripts/import-math.sh, then fprime-util build qnx-x86_64 in adoption/math-tutorial.' >&2
    exit 1
}
command -v fprime-gds >/dev/null
command -v fprime-cli >/dev/null
evidence_root=$(realpath -e "${GDS_EVIDENCE_ROOT:-${TMPDIR:-/tmp}}")
case "$evidence_root/" in "$root/"*) echo 'Use an evidence directory outside the repository.' >&2; exit 2 ;; esac
run=$(mktemp -d "$evidence_root/math-gds.XXXXXXXX")
printf 'Math GDS evidence: %s\n' "$run"

fail() { printf 'FAIL %s (see %s)\n' "$*" "$run" | tee -a "$run/verdict.txt" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*" | tee -a "$run/verdict.txt"; }

image=${QNX_IMAGE_DIR:-$run/image}
key=${QNX_SSH_KEY:-$run/id_ed25519}
ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
guest=
target_dir=
gds_pid=
capture_pid=
endpoint_dir=
cleanup() {
    set +e
    if [[ -n "$target_dir" ]]; then
        ssh "${ssh_opts[@]}" "root@$guest" \
            "cd '$target_dir' && { [ ! -s math.pid ] || kill -KILL \$(cat math.pid); } 2>/dev/null; cat math.log" \
            </dev/null >"$run/target-console.log" 2>>"$run/cleanup.log"
        ssh "${ssh_opts[@]}" "root@$guest" \
            "cd '$target_dir' && rm -f MathProject_MathDeployment math.log math.pid PrmDb.dat && cd / && rmdir '$target_dir'" \
            </dev/null >>"$run/cleanup.log" 2>&1
    fi
    if [[ -n "$capture_pid" ]]; then
        kill -TERM "$capture_pid" 2>/dev/null
        wait "$capture_pid" 2>/dev/null
    fi
    if [[ -n "$gds_pid" ]]; then
        # fprime-gds starts helper processes; stop its whole session so none keeps the port or ZMQ endpoints.
        kill -TERM -- "-$gds_pid" 2>/dev/null
        wait "$gds_pid" 2>/dev/null
    fi
    if [[ -n "$endpoint_dir" ]]; then
        rm -f -- "$endpoint_dir/in" "$endpoint_dir/out"
        rmdir -- "$endpoint_dir"
    fi
    if (( started )) && qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >>"$run/cleanup.log" 2>&1
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
    git -C "$root" rev-parse HEAD
    git -C "$root" status --short
    git -C "$root" submodule status --recursive
    git -C "$root/adoption/math-tutorial" rev-parse HEAD
    git -C "$root/adoption/math-tutorial" diff --stat
    git -C "$root/adoption/math-tutorial/lib/fprime" rev-parse HEAD
    qcc -V
    qemu-system-x86_64 --version
    sha256sum "$binary" "$dictionary"
} >"$run/source.txt" 2>&1

# 1. Guest
if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir "$image"
    if [[ -z "${QNX_SSH_KEY:-}" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    [[ -r "$key" && -r "$key.pub" ]] || fail 'QNX SSH identity unavailable'
    qnx_vm_build_image "$image" fprime-math "$key.pub" >"$run/image.log" 2>&1 || fail 'guest image build failed'
fi
image=$(cd "$image" && pwd -P)
if ! qnx_vm_running "$image"; then
    started=1
    qnx_vm_start "$image" "$run/guest-boot.log" || fail 'could not boot the guest'
fi
guest=$(qnx_vm_find_guest "$image" "${ssh_opts[@]}") || fail 'QNX guest unavailable'
ssh "${ssh_opts[@]}" "root@$guest" uname -a </dev/null >"$run/target-uname.txt"
host_ip=$(ip -4 -o addr show virbr0 | awk '{sub(/\/.*/, "", $4); print $4; exit}')
[[ "$host_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail 'virbr0 IPv4 address missing'

# 2. GDS (TCP server, no GUI) and a recorder for the decoded events and telemetry
port=${GDS_PORT:-$(python3 - "$host_ip" <<'PY'
import socket
import sys
with socket.socket() as listener:
    listener.bind((sys.argv[1], 0))
    print(listener.getsockname()[1])
PY
)}
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || fail 'invalid GDS_PORT'
endpoint_dir=$(mktemp -d /tmp/fgds.XXXXXXXX)
ipc=("ipc://$endpoint_dir/in" "ipc://$endpoint_dir/out")
mkdir "$run/gds" "$run/capture"
setsid --wait fprime-gds -n -g none --dictionary "$dictionary" \
    --framing-selection space-packet-space-data-link --ip-address "$host_ip" --ip-port "$port" \
    --zmq-transport "${ipc[@]}" -l "$run/gds" --log-directly \
    </dev/null >"$run/gds/stdout.log" 2>&1 &
gds_pid=$!
deadline=$((SECONDS + 20))
until ss -H -ltn "src $host_ip and sport = :$port" | grep -q . && [[ -S "$endpoint_dir/out" ]]; do
    kill -0 "$gds_pid" 2>/dev/null || fail 'GDS TCP bridge exited'
    (( SECONDS < deadline )) || fail 'GDS TCP bridge unavailable'
    sleep 0.2
done
python3 "$root/FprimeQnxReference/test/int/capture-gds.py" --dictionary "$dictionary" --zmq-transport "${ipc[@]}" \
    --file-storage-directory "$run/capture" -l "$run/capture" --log-directly \
    >"$run/capture/stdout.log" 2>&1 &
capture_pid=$!
events=$run/capture/event.log
channels=$run/capture/channel.log

# wait_log FILE FROM_LINE PATTERN: wait for PATTERN in FILE after line FROM_LINE.
wait_log() {
    local file=$1 from=$2 pattern=$3 deadline=$((SECONDS + ${4:-30}))
    until tail -n "+$((from + 1))" "$file" 2>/dev/null | grep -Eq -- "$pattern"; do
        kill -0 "$capture_pid" 2>/dev/null || fail 'GDS capture exited'
        kill -0 "$gds_pid" 2>/dev/null || fail 'GDS exited'
        (( SECONDS < deadline )) || fail "GDS did not report $pattern"
        sleep 0.2
    done
}
lines() { wc -l <"$1" 2>/dev/null || echo 0; }
send() {  # send NAME COMMAND [ARGUMENTS...]
    local name=$1 command=$2
    shift 2
    local arguments=()
    (( $# == 0 )) || arguments=(--arguments "$@")
    mkdir "$run/$name"
    timeout 20s fprime-cli command-send "$command" "${arguments[@]}" --dictionary "$dictionary" \
        --zmq-transport "${ipc[@]}" -l "$run/$name" --log-directly \
        >"$run/$name/stdout.log" 2>&1 || fail "$command uplink failed"
}
wait_log "$run/capture/stdout.log" 0 '^GDS capture ready$'

# 3. MathDeployment on the target
target_dir=$(ssh "${ssh_opts[@]}" "root@$guest" 'mktemp -d /tmp/fprime-math.XXXXXXXX' </dev/null)
[[ "$target_dir" =~ ^/tmp/fprime-math\.[a-zA-Z0-9]+$ ]] || fail 'invalid guest work directory'
scp -q "${ssh_opts[@]}" "$binary" "root@$guest:$target_dir/" || fail 'copy to the guest failed'
# -f: the QNX shell keeps the channel open for its background job, so let ssh go to the background after auth.
ssh -n -f "${ssh_opts[@]}" "root@$guest" \
    "cd '$target_dir' && { nohup ./MathProject_MathDeployment -a $host_ip -p $port >math.log 2>&1 </dev/null & echo \$! >math.pid; }" ||
    fail 'could not start MathDeployment'
# rate group 1, driven by Svc.QnxTimer, runs CdhCore.tlmSend, so its own telemetry shows the link and the tick
wait_log "$channels" 0 '\.rateGroup1\.Rg[[:alpha:]]+,' 60
pass 'MathDeployment connected and rate group 1 downlinks telemetry'

# 4. Commands, events and telemetry
mark=$(lines "$events")
send noop CdhCore.cmdDisp.CMD_NO_OP
wait_log "$events" "$mark" '\.cmdDisp\.NoOpReceived,'
wait_log "$events" "$mark" '\.cmdDisp\.OpCodeCompleted,'
pass 'CMD_NO_OP gives NoOpReceived and OpCodeCompleted'

mark=$(lines "$events")
mark_tlm=$(lines "$channels")
send add MathProject.mathSender.DO_MATH 1 ADD 2
wait_log "$events" "$mark" '\.mathSender\.COMMAND_RECV,'
wait_log "$events" "$mark" '\.mathReceiver\.OPERATION_PERFORMED,.*ADD'
wait_log "$events" "$mark" '\.mathSender\.RESULT,.*Math result is 3(\.0*)?$'
wait_log "$channels" "$mark_tlm" '\.mathSender\.RESULT,[^,]*,3(\.0*)?$'
wait_log "$channels" "$mark_tlm" '\.mathReceiver\.NUMBER_OF_OPS,[^,]*,1$'
pass 'DO_MATH 1 ADD 2 gives OPERATION_PERFORMED, RESULT 3 and the result telemetry'

mark=$(lines "$events")
send factor MathProject.mathReceiver.FACTOR_PRM_SET 2
wait_log "$events" "$mark" '\.mathReceiver\.FACTOR_UPDATED,.*Factor updated to 2(\.0*)?$'
pass 'FACTOR parameter set gives FACTOR_UPDATED'

mark=$(lines "$events")
mark_tlm=$(lines "$channels")
send add-factor MathProject.mathSender.DO_MATH 1 ADD 2
wait_log "$events" "$mark" '\.mathSender\.RESULT,.*Math result is 6(\.0*)?$'
wait_log "$channels" "$mark_tlm" '\.mathSender\.RESULT,[^,]*,6(\.0*)?$'
pass 'DO_MATH 1 ADD 2 with FACTOR 2 gives RESULT 6'

mark=$(lines "$events")
send divide MathProject.mathSender.DO_MATH 1 DIV 0
wait_log "$events" "$mark" '\.mathReceiver\.DIVIDE_BY_ZERO,'
pass 'DO_MATH 1 DIV 0 gives DIVIDE_BY_ZERO'

# 5. Orderly shutdown through the signal handler, which calls Svc.QnxTimer quit()
ssh "${ssh_opts[@]}" "root@$guest" "cd '$target_dir' && kill -TERM \$(cat math.pid)" </dev/null ||
    fail 'could not signal MathDeployment'
deadline=$((SECONDS + 15))
until ssh "${ssh_opts[@]}" "root@$guest" "cd '$target_dir' && ! kill -0 \$(cat math.pid) 2>/dev/null" </dev/null; do
    (( SECONDS < deadline )) || fail 'MathDeployment did not exit after SIGTERM'
    sleep 1
done
ssh "${ssh_opts[@]}" "root@$guest" "cd '$target_dir' && grep -q '^Exiting' math.log" </dev/null ||
    fail 'MathDeployment exited without completing teardown'
pass 'SIGTERM stops the QNX timer and the deployment exits through teardown'
printf 'PASS math GDS check\n' | tee -a "$run/verdict.txt"
