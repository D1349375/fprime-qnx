#!/usr/bin/env bash
# Build and run the deterministic M3 validation on a single QNX x86-64 guest.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/qnx-vm.sh"
project="$root/FprimeQnxReference"
rounds="${1:-10}"
if [[ "$rounds" == --help && $# == 1 ]]; then
    echo 'Usage: scripts/m3-check.sh [rounds-per-scenario] (default: 10, use 1 for a pilot)'
    exit 0
fi
[[ $# -le 1 && "$rounds" =~ ^[1-9][0-9]*$ ]] || { echo 'Expected a positive round count' >&2; exit 2; }
: "${QNX_TARGET:?Source the QNX SDP environment first}"
sdk="$QNX_TARGET/x86_64"
run="$(mktemp -d "${TMPDIR:-/tmp}/fprime-m3.XXXXXXXX")"
printf 'M3 evidence: %s\n' "$run"

(
    git -C "$root" rev-parse HEAD
    git -C "$root" status --short
    git -C "$root" submodule status --recursive
    qcc -V
) >"$run/source.txt" 2>&1
"${CXX:-c++}" -std=c++14 -Wall -Wextra -Werror -pedantic -I"$project" \
    "$project/test/int/recovery-policy.cpp" "$project/Components/Link/Protocol.cpp" -o "$run/recovery-policy" \
    >"$run/host-policy-build.log" 2>&1 || { cat "$run/host-policy-build.log"; exit 1; }
"$run/recovery-policy" | tee "$run/host-policy.log"
(
    cd "$project"
    if [[ ! -f build-fprime-automatic-qnx-x86_64/CMakeCache.txt ]]; then
        fprime-util generate qnx-x86_64
    fi
    fprime-util build qnx-x86_64 --jobs "${BUILD_JOBS:-2}"
) >"$run/build.log" 2>&1 || { tail -30 "$run/build.log"; exit 1; }

artifacts="$project/build-artifacts/qnx-x86_64"
flight="$artifacts/FlightSW/bin/FlightSW"
advisor="$artifacts/MlAdvisor/bin/MlAdvisor"
observer="$run/watch-death"
qcc -Vgcc_ntox86_64 -D_QNX_SOURCE -std=c11 -Wall -Wextra "$project/test/int/watch-death.c" -o "$observer" \
    >"$run/death-watch-build.log" 2>&1 || { cat "$run/death-watch-build.log"; exit 1; }
sha256sum "$flight" "$advisor" "$observer" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" >"$run/binaries.sha256"
image="${QNX_IMAGE_DIR:-$run/image}"
key="${QNX_SSH_KEY:-$run/ssh/id_ed25519}"
if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir -m 700 "$run/ssh"
    mkdir "$image"
    if [[ ! -f "$key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    qnx_vm_build_image "$image" fprime-m3 "$key.pub" --data-size=256 >"$run/image.log" 2>&1
else
    image="$(cd "$image" && pwd -P)"
fi
cp "$image/output/options" "$run/image-options.txt"
find -L "$image/output" -maxdepth 1 -type f \
    \( -name '*.img' -o -name '*.ifs' -o -name '*.iso' -o -name '*.qcow2' -o -name '*.raw' \
       -o -name '*.vmdk' -o -name 'ifs.bin' \) \
    -print0 | sort -z | xargs -0 -r sha256sum >"$run/image.sha256"
if [[ ! -s "$run/image.sha256" ]]; then
    echo "No boot image found for the evidence manifest in $image/output" >&2
    exit 1
fi

ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
target=
target_dir=
cleanup() {
    if [[ -n "$target_dir" ]]; then
        # Only the files staged by the harness are removed.
        ssh "${ssh_opts[@]}" "$target" "cd '$target_dir' || exit 1
            rm -f FlightSW MlAdvisor watch-death slm slmctl run-m3-target.sh m3-slm.xml.in m3-slm.xml
            rm -f flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log death.csv death.log
            rm -f slm-libs/libexpat.so.2 slm-libs/libsecpol.so.1 slm-libs/libqh.so.1
            cd .. && rmdir '$target_dir/slm-libs' '$target_dir'" </dev/null >>"$run/cleanup.log" 2>&1 || true
    fi
    if (( started )) && qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >>"$run/cleanup.log" 2>&1 || true
    fi
}
trap cleanup EXIT
if ! qnx_vm_running "$image"; then
    started=1
    qnx_vm_start "$image" "$run/guest-boot.log"
fi
qemu_pid="$(cat "$image/output/qemu.pid")"
tr '\0' '\n' <"/proc/$qemu_pid/cmdline" >"$run/qemu-argv.txt"
guest="$(qnx_vm_find_guest "$image" "${ssh_opts[@]}")"
target="root@$guest"
ssh "${ssh_opts[@]}" "$target" uname -a | tee "$run/target-uname.txt"
grep -q '^QNX.*x86' "$run/target-uname.txt"

created="$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/fprime-m3.XXXXXXXX')"
[[ "$created" =~ ^/tmp/fprime-m3\.[a-zA-Z0-9]+$ ]]
target_dir="$created"
ssh "${ssh_opts[@]}" "$target" "mkdir '$target_dir/slm-libs'"
scp -q "${ssh_opts[@]}" "$flight" "$advisor" "$observer" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" \
    "$project/qnx/m3-slm.xml.in" "$project/test/int/run-m3-target.sh" "$target:$target_dir/"
scp -q "${ssh_opts[@]}" "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" \
    "$target:$target_dir/slm-libs/"
files=(flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log death.csv death.log m3-slm.xml)

result=0
printf 'run_id\tgroup\ttarget_exit\tverdict\n' >"$run/results.tsv"
for ((n = 1; n <= rounds; ++n)); do
    # Alternate order to avoid putting Q2 systematically later in each block.
    groups=(normal q1 q2 stall gate geometry transport recovery)
    if (( n % 2 == 0 )); then
        groups=(normal q2 q1 stall gate geometry transport recovery)
    fi
    for group in "${groups[@]}"; do
        scenario="$group"
        repair=restart
        case "$group" in
            q1) scenario=crash ;;
            q2) scenario=crash; repair=none ;;
        esac
        run_id="$(printf '%03d-%s' "$n" "$group")"
        round="$run/$run_id"
        mkdir "$round"
        printf '%s\n' "run_id=$run_id" "group=$group" "scenario=$scenario" "repair=$repair" \
            'cycles=230' 'period_ns=20000000' 'deadline_ns=20000000' 'freshness_ns=250000000' \
            'fallback_limit_ns=300000000' 'q1_rejoin_limit_ns=1800000000' 'stall_rejoin_limit_ns=900000000' \
            'transport_rejoin_limit_ns=900000000' 'min_warmup_cycles=40' 'injection_cycle=55' \
            'transport_pause_ns=400000000' 'angle_limit_deg=2' 'stable_cycles=20' \
            'seed=none' 'workload=fixture-only' 'crash_signal=SIGKILL' 'slm_rate=2/min' 'slm_backoff_s=1' \
            'exit_observer=procmgr' >"$round/config.txt"
        rc=0
        timeout -k 5s 28s ssh "${ssh_opts[@]}" "$target" \
            "sh '$target_dir/run-m3-target.sh' '$target_dir' '$scenario' '$repair'" >"$round/target.log" 2>&1 || rc=$?
        printf '%s\n' "$rc" >"$round/target-status.txt"
        for name in "${files[@]}"; do
            scp -q "${ssh_opts[@]}" "$target:$target_dir/$name" "$round/$name" 2>>"$round/target.log" || true
        done
        if python3 "$project/test/int/check-m3.py" "$round" | tee "$round/summary.txt"; then
            verdict=PASS
        else
            assessment_status=$?
            verdict=INDETERMINATE
            if [[ "$assessment_status" -eq 1 ]]; then
                verdict=FAIL
            fi
            result=1
        fi
        printf '%s\t%s\t%s\t%s\n' "$run_id" "$group" "$rc" "$verdict" >>"$run/results.tsv"
    done
    # The only XML change within a pair must be the advisor repair policy.
    q1="$run/$(printf '%03d-q1' "$n")/m3-slm.xml"
    q2="$run/$(printf '%03d-q2' "$n")/m3-slm.xml"
    if ! sed 's/backoff="1">none</backoff="1">restart</' "$q2" | cmp -s "$q1" -; then
        printf 'Pair %d has inconsistent SLM configuration\n' "$n" | tee -a "$run/pairs.txt"
        result=1
    fi
done
printf 'M3 results: %s\n' "$run/results.tsv"
exit "$result"
