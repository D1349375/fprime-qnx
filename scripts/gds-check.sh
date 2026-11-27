#!/usr/bin/env bash
# Exercise FlightSW, SLM, and the pinned F Prime GDS on one QNX x86-64 guest.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/qnx-vm.sh"
project=$root/FprimeQnxReference
ui=0
rounds=0
scene=normal
gate_status=0
case "${1:-}" in
    --ui) ui=1; shift ;;
    --gate-explanation) scene=recovery; shift ;;
    --gate-status) scene=recovery; gate_status=1; shift ;;
    --timing)
        [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Expected a positive timing round count' >&2; exit 2; }
        rounds=$2
        shift 2
        ;;
    --help) echo 'Usage: scripts/gds-check.sh [--ui | --gate-explanation | --gate-status | --timing ROUNDS]'; exit 0 ;;
esac
[[ $# -eq 0 ]] || { echo 'Usage: scripts/gds-check.sh [--ui | --gate-explanation | --gate-status | --timing ROUNDS]' >&2; exit 2; }

: "${QNX_TARGET:?Source the QNX SDP environment first}"
sdk=$QNX_TARGET/x86_64
artifacts=$project/build-artifacts/qnx-x86_64
flight=$artifacts/FlightSW/bin/FlightSW
advisor=$artifacts/MlAdvisor/bin/MlAdvisor
dictionary=$artifacts/FlightSW/dict/FlightTopologyDictionary.json
[[ -x "$flight" && -x "$advisor" && -r "$dictionary" ]] || {
    echo 'Build FprimeQnxReference for qnx-x86_64 first.' >&2
    exit 1
}
command -v fprime-gds >/dev/null
command -v fprime-cli >/dev/null
evidence_root=$(realpath -e "${GDS_EVIDENCE_ROOT:-${TMPDIR:-/tmp}}")
case "$evidence_root/" in "$root/"*) echo 'Use an evidence directory outside the repository.' >&2; exit 2 ;; esac
run=$(mktemp -d "$evidence_root/fprime-gds.XXXXXXXX")
printf 'GDS evidence: %s\n' "$run"

fail() { printf 'FAIL %s (see %s)\n' "$*" "$run" >&2; exit 1; }

image=${QNX_IMAGE_DIR:-$run/image}
key=${QNX_SSH_KEY:-$run/id_ed25519}
ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
target_dir=
target_pid=
gds_pid=
capture_pid=
endpoint_dir=
guest=
flight_pid=
stop_gds() {
    if [[ -n "$gds_pid" ]]; then
        stop_process_group "$gds_pid"
        gds_pid=
    fi
}
cleanup() {
    set +e
    stop_gds
    if [[ -n "$capture_pid" ]]; then
        kill -TERM "$capture_pid" 2>/dev/null
        wait "$capture_pid" 2>/dev/null
    fi
    if [[ -n "$endpoint_dir" ]]; then
        rm -f -- "$endpoint_dir/in" "$endpoint_dir/out"
        rmdir -- "$endpoint_dir"
    fi
    if [[ -n "$target_dir" ]]; then
        if [[ -n "$target_pid" ]]; then
            ssh "${ssh_opts[@]}" "root@$guest" \
                "cd '$target_dir' && ./slmctl -n '/dev/slm-fprime-gds-${target_dir##*.}' 'stop m3'" \
                </dev/null >>"$run/cleanup.log" 2>&1
            kill "$target_pid" 2>/dev/null
            wait "$target_pid" 2>/dev/null
        fi
        mkdir -p "$run/target"
        for file in flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log gds-slm.xml; do
            scp -q "${ssh_opts[@]}" "root@$guest:$target_dir/$file" "$run/target/" >>"$run/cleanup.log" 2>&1
        done
        ssh "${ssh_opts[@]}" "root@$guest" \
            "cd '$target_dir' && rm -f FlightSW MlAdvisor slm slmctl run-gds-target.sh m3-slm.xml.in gds-slm.xml \
                flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log \
                slm-libs/libexpat.so.2 slm-libs/libsecpol.so.1 slm-libs/libqh.so.1 \
                && cd .. && rmdir '$target_dir/slm-libs' '$target_dir'" \
            </dev/null >>"$run/cleanup.log" 2>&1
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
    qcc -V
    qemu-system-x86_64 --version
    sha256sum "$flight" "$advisor" "$dictionary"
} >"$run/source.txt" 2>&1

if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir "$image"
    if [[ -z "${QNX_SSH_KEY:-}" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    [[ -r "$key" && -r "$key.pub" ]] || fail 'QNX SSH identity unavailable'
    qnx_vm_build_image "$image" fprime-gds "$key.pub" --data-size=256 >"$run/image.log" 2>&1
fi
image=$(cd "$image" && pwd -P)
if ! qnx_vm_running "$image"; then
    started=1
    qnx_vm_start "$image" "$run/guest-boot.log"
fi
qemu_pid=$(cat "$image/output/qemu.pid")
tr '\0' '\n' <"/proc/$qemu_pid/cmdline" >"$run/qemu-argv.txt"
guest=$(qnx_vm_find_guest "$image" "${ssh_opts[@]}") || fail 'QNX guest unavailable'
ssh "${ssh_opts[@]}" "root@$guest" uname -a >"$run/target-uname.txt"
host_ip=$(ip -4 -o addr show virbr0 | awk '{sub(/\/.*/, "", $4); print $4; exit}')
[[ "$host_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail 'virbr0 IPv4 address missing'

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
gui=(-g none)
if (( ui )); then
    gui=(--skip-browser-open --gui-port "${GDS_GUI_PORT:-5000}")
fi

start_gds() {
    local phase=$1
    mkdir -p "$run/$phase"
    setsid --wait fprime-gds -n "${gui[@]}" --dictionary "$dictionary" \
        --framing-selection space-packet-space-data-link --ip-address "$host_ip" --ip-port "$port" \
        --zmq-transport "${ipc[@]}" -l "$run/$phase" --log-directly \
        </dev/null >"$run/$phase/stdout.log" 2>&1 &
    gds_pid=$!
    local deadline=$((SECONDS + 20))
    until ss -H -ltn "src $host_ip and sport = :$port" | grep -q . && [[ -S "$endpoint_dir/out" ]]; do
        kill -0 "$gds_pid" 2>/dev/null || fail 'GDS TCP bridge exited'
        (( SECONDS < deadline )) || fail 'GDS TCP bridge unavailable'
        sleep 0.2
    done
}

wait_log() {
    local file=$1 pattern=$2 deadline=$((SECONDS + ${3:-30}))
    until grep -Eq "$pattern" "$file" 2>/dev/null; do
        kill -0 "$capture_pid" 2>/dev/null || fail 'GDS capture exited'
        kill -0 "$gds_pid" 2>/dev/null || fail 'GDS exited'
        (( SECONDS < deadline )) || fail "GDS did not report $pattern"
        sleep 0.2
    done
}

start_gds gds
candidate=$(ssh "${ssh_opts[@]}" "root@$guest" 'mktemp -d /tmp/fprime-gds.XXXXXXXX')
[[ "$candidate" =~ ^/tmp/fprime-gds\.[a-zA-Z0-9]+$ ]] || fail 'invalid guest work directory'
target_dir=$candidate
ssh "${ssh_opts[@]}" "root@$guest" "mkdir '$target_dir/slm-libs'"
scp -q "${ssh_opts[@]}" "$flight" "$advisor" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" \
    "$project/qnx/m3-slm.xml.in" "$root/scripts/run-gds-target.sh" "root@$guest:$target_dir/"
scp -q "${ssh_opts[@]}" "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" \
    "root@$guest:$target_dir/slm-libs/"
seed=${GDS_SEED:-42}
[[ "$seed" =~ ^[1-9][0-9]*$ ]] || fail 'invalid GDS_SEED'
printf 'seed=%s\nscenario=%s\n' "$seed" "$scene" >"$run/scenario.txt"

if (( rounds )); then
    printf 'pair\tgds\tmissing\tlate\tinvalid\n' >"$run/timing.tsv"
    for (( pair=1; pair<=rounds; ++pair )); do
        modes=(off on)
        if (( pair % 2 == 0 )); then modes=(on off); fi
        for mode in "${modes[@]}"; do
            round=$run/$(printf '%03d-%s' "$pair" "$mode")
            mkdir "$round"
            endpoint=-
            expected_priority=30
            if [[ "$mode" == on ]]; then
                endpoint=$host_ip:$port
                expected_priority=60
            fi
            remote_status=0
            timeout -k 5s 25s ssh "${ssh_opts[@]}" "root@$guest" \
                "sh '$target_dir/run-gds-target.sh' '$target_dir' '$endpoint' '$seed' 230" \
                </dev/null >"$round/target-ssh.log" 2>&1 || remote_status=$?
            for file in flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log gds-slm.xml; do
                scp -q "${ssh_opts[@]}" "root@$guest:$target_dir/$file" "$round/" >>"$round/target-ssh.log" 2>&1 || true
            done
            (( remote_status == 0 )) || fail "SLM run failed in $round"
            counts=$(python3 "$project/test/int/check-gds-timing.py" "$round" --fifo-priority "$expected_priority")
            printf '%s\t%s\t%s\n' "$pair" "$mode" "$counts" >>"$run/timing.tsv"
        done
        printf 'Completed timing pair %s/%s\n' "$pair" "$rounds"
    done
    printf 'Timing data captured in %s/timing.tsv\n' "$run"
    exit 0
fi

mkdir "$run/capture"
python3 "$project/test/int/capture-gds.py" --dictionary "$dictionary" --zmq-transport "${ipc[@]}" \
    --file-storage-directory "$run/capture" -l "$run/capture" --log-directly \
    >"$run/capture/stdout.log" 2>&1 &
capture_pid=$!
wait_log "$run/capture/stdout.log" '^GDS capture ready$'
events=$run/capture/event.log
channels=$run/capture/channel.log
ssh "${ssh_opts[@]}" "root@$guest" \
    "sh '$target_dir/run-gds-target.sh' '$target_dir' '$host_ip:$port' '$seed' 0 '$scene' '$gate_status'" \
    </dev/null >"$run/target-ssh.log" 2>&1 &
target_pid=$!

wait_log "$channels" '\.ground\.AdvisorSession,[^,]+,[1-9][0-9]*$'
wait_log "$channels" '\.ground\.ControlSource,[^,]+,ML$'
flight_pid=$(ssh "${ssh_opts[@]}" "root@$guest" \
    "sed -nE 's/^READY pid=([0-9]+).* fifo_priority=60$/\1/p' '$target_dir/flight.log'")
[[ "$flight_pid" =~ ^[1-9][0-9]*$ ]] || fail 'FlightSW did not report GDS scheduling'
ssh "${ssh_opts[@]}" "root@$guest" "pidin -P '$flight_pid' -F '%a %b %N %p'" \
    | awk -v pid="$flight_pid" '$1 == pid' >"$run/target-threads.txt"
for priority in 60f 44r 43r 42r 41r; do
    grep -Eq "[[:space:]]${priority}[[:space:]]*$" "$run/target-threads.txt" ||
        fail "missing expected ground-enabled scheduling policy ($priority)"
done

send_noop() {
    local phase=$1
    mkdir "$run/$phase"
    timeout 10s fprime-cli command-send CdhCore.cmdDisp.CMD_NO_OP --dictionary "$dictionary" \
        --zmq-transport "${ipc[@]}" -l "$run/$phase" --log-directly \
        >"$run/$phase/stdout.log" 2>&1 || fail 'CMD_NO_OP uplink failed'
}

send_noop command
wait_log "$events" '\.cmdDisp\.NoOpReceived,'
wait_log "$events" '\.cmdDisp\.OpCodeCompleted,'

if [[ "$scene" == recovery ]]; then
    wait_log "$events" '\.ground\.GateDecision,.*Gate R[0-9]_[A-Z_]+ REJECTED\. [[:alpha:]]'
    wait_log "$events" '\.ground\.GateDecision,.*Gate APPROVED APPROVED\. Independent checks permit the sensor exclusion'
    printf 'PASS GDS shows Gate approval and rejection reasons\n'
fi

if (( gate_status )); then
    ssh "${ssh_opts[@]}" "root@$guest" /bin/sh -s >"$run/gate-status.txt" 2>"$run/gate-status.err" <<'TARGET'
set -eu
test -c /dev/fprime/gate
dd if=/dev/fprime/gate bs=7 2>/dev/null
if (printf 'write must fail\n' >/dev/fprime/gate); then
    echo 'Gate status unexpectedly accepted a write open' >&2
    exit 1
fi
TARGET
    grep -Fxq 'advisor=active' "$run/gate-status.txt" || fail 'Gate status did not report an active advisor'
    grep -Eq '^last_decision=(APPROVED|R[0-9]_[A-Z_]+)$' "$run/gate-status.txt" || fail 'Gate status lacks a decision'
    grep -Eq '^advisor_rejections=[1-9][0-9]*$' "$run/gate-status.txt" || fail 'Gate status lacks a rejection count'
    printf 'PASS Gate snapshot and write denial\n'
fi

if (( ui )); then
    printf 'GDS at http://localhost:%s. Open Events, then press Enter here to stop the advisor.\n' "${GDS_GUI_PORT:-5000}"
    read -r || true
fi

# The system-wide subscription must ignore a different child's exit.
ssh "${ssh_opts[@]}" "root@$guest" /bin/sh -s >"$run/unrelated-exit.log" 2>&1 <<'TARGET'
set -eu
/bin/sh -c 'exit 0' &
unrelated=$!
wait "$unrelated"
printf 'Unrelated process exited pid=%s\n' "$unrelated"
TARGET
crash_event=$(wc -l <"$events")
crash_channel=$(wc -l <"$channels")
ssh "${ssh_opts[@]}" "root@$guest" "/bin/sh -s '$target_dir' '$flight_pid'" \
    >"$run/injection.log" 2>&1 <<'TARGET'
set -eu
cd "$1"
kill -0 "$2"
pid=$(awk -F, '$2 == "SESSION" {pid = $3} END {print pid}' link.csv)
case "$pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
pidin -P "$pid" -F '%a %N' | awk -v target="$pid" '$1 == target && $2 == "MlAdvisor" {found=1} END {exit !found}'
printf 'Stopping staged MlAdvisor pid=%s\n' "$pid"
kill -9 "$pid"
TARGET

advisor_pid=$(sed -nE 's/^Stopping staged MlAdvisor pid=([0-9]+)$/\1/p' "$run/injection.log")
[[ "$advisor_pid" =~ ^[1-9][0-9]*$ ]] || fail 'stopped advisor PID unavailable'
deadline=$((SECONDS + 30))
until python3 "$project/test/int/check-gds.py" "$run/capture" "$crash_event" "$crash_channel" "$advisor_pid" >"$run/verdict.txt" 2>&1; do
    kill -0 "$target_pid" 2>/dev/null || fail 'SLM stopped during the advisor restart'
    (( SECONDS < deadline )) || { cat "$run/verdict.txt"; fail 'GDS event or telemetry verification failed after the advisor restart'; }
    sleep 0.2
done
cat "$run/verdict.txt"

ssh "${ssh_opts[@]}" "root@$guest" "/bin/sh -s '$target_dir' '$flight_pid' '$advisor_pid'" \
    >"$run/sessions.csv" 2>"$run/session-check.log" <<'TARGET'
set -eu
cd "$1"
kill -0 "$2"
replacement=$(awk -F, '$2 == "SESSION" {pid = $3} END {print pid}' link.csv)
case "$replacement" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$replacement" != "$3" ]
pidin -P "$replacement" -F '%a %N' |
    awk -v target="$replacement" '$1 == target && $2 == "MlAdvisor" {found=1} END {exit !found}'
awk -F, '$2 == "SESSION" {print $3 "," $4}' link.csv
TARGET

if (( ui )); then
    printf 'GDS at http://localhost:%s. Press Enter here to continue with the reconnect check.\n' "${GDS_GUI_PORT:-5000}"
    read -r || true
fi

stop_gds
before=$(ssh "${ssh_opts[@]}" "root@$guest" "wc -l < '$target_dir/flight.csv'")
sleep 2
after=$(ssh "${ssh_opts[@]}" "root@$guest" "kill -0 '$flight_pid' && wc -l < '$target_dir/flight.csv'")
(( after > before )) || fail 'FlightSW made no progress while GDS was down'
reconnect_channel=$(wc -l <"$channels")
start_gds gds-reconnected
deadline=$((SECONDS + 35))
until tail -n "+$((reconnect_channel + 1))" "$channels" | grep -E '\.ground\.ControlSource,[^,]+,ML$' >/dev/null; do
    (( SECONDS < deadline )) || fail 'GDS did not recover current control telemetry'
    sleep 0.2
done
reconnect_event=$(wc -l <"$events")
send_noop command-reconnected
deadline=$((SECONDS + 30))
until tail -n "+$((reconnect_event + 1))" "$events" | grep -E '\.cmdDisp\.OpCodeCompleted,' >/dev/null; do
    (( SECONDS < deadline )) || fail 'GDS did not receive the reconnected command completion'
    sleep 0.2
done
printf 'PASS FlightSW kept running and GDS reconnected\n'

ssh "${ssh_opts[@]}" "root@$guest" "kill -TERM '$flight_pid'"
wait "$target_pid" || fail 'FlightSW or SLM did not shut down cleanly'
target_pid=
if (( gate_status )); then
    ssh "${ssh_opts[@]}" "root@$guest" 'test ! -e /dev/fprime/gate' || fail 'Gate status path survived shutdown'
fi
python3 "$project/test/int/check-gds.py" "$run/capture" "$crash_event" "$crash_channel" "$advisor_pid" \
    --sessions "$run/sessions.csv" >"$run/final-verdict.txt" 2>&1 || {
        cat "$run/final-verdict.txt"
        fail 'final GDS and advisor PID verification'
    }
grep -F 'PASS SLM replaced the advisor' "$run/final-verdict.txt"
printf 'PASS FlightSW shutdown\n'
