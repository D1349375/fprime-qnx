#!/usr/bin/env bash
# Cross-build the pinned upstream OSAL suites and execute them in a QNX x86-64 guest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/qnx-vm.sh"

fail() { printf 'osal-check: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    cat <<'EOF'
Usage: scripts/osal-check.sh

Source the QNX SDP 8.0 environment, activate the F Prime venv, and provision an
x86-64 mkqnximage guest with an SSH key. The script boots the guest if needed.
Optional environment: QNX_IMAGE_DIR (default: ~/qnx/images/smoke), QNX_SSH_KEY
(default: ~/.ssh/qnx_vm), QNX_KNOWN_HOSTS, OSAL_BUILD_DIR (reuse a cache from
this checkout), BUILD_JOBS (default: 2), TEST_SECONDS (default: 90).
EOF
    exit 0
fi
(( $# == 0 )) || fail 'see --help for available settings'
[[ -n "${QNX_HOST:-}" && -n "${QNX_TARGET:-}" ]] || fail 'source qnxsdp-env.sh first'
command -v fprime-util >/dev/null || fail 'activate the F Prime venv first'

image_dir="$(cd "${QNX_IMAGE_DIR:-$HOME/qnx/images/smoke}" && pwd -P)" ||
    fail 'QNX image directory not found'
key="$(realpath -e -- "${QNX_SSH_KEY:-$HOME/.ssh/qnx_vm}")" || fail 'QNX SSH key not found'
[[ -r "$key" ]] || fail 'QNX SSH key is unreadable'
jobs="${BUILD_JOBS:-2}"
seconds="${TEST_SECONDS:-90}"
[[ "$jobs" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] ||
    fail 'BUILD_JOBS and TEST_SECONDS must be positive integers'

mkdir -p "$ROOT/adoption/logs"
run_dir="$(mktemp -d "$ROOT/adoption/logs/osal-check-$(date +%Y%m%d-%H%M%S).XXXXXXXX")"
printf 'OSAL evidence: %s\n' "$run_dir"
build_dir="$(realpath -m -- "${OSAL_BUILD_DIR:-$run_dir/build}")"
known_hosts="${QNX_KNOWN_HOSTS:-$run_dir/known_hosts}"
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=\"$known_hosts\"" -o ConnectTimeout=5 -o BatchMode=yes)

suites=(
    Os_ut_exe Os_FilePathUtils_Test Os_SandboxedFile_Test
    PosixFileTest PosixConsoleTest PosixTaskTest PosixMutexTest PosixFileSystemTest
    PosixDirectoryTest PosixConditionTests PosixCountingSemaphoreTest PosixRawTimeTest
    PriorityMemQueue_UnitTest PriorityQueueTest LocklessPriorityQueueTest
    StubCpuTest StubMemoryTest
)
(
    cd "$ROOT"
    git rev-parse HEAD
    git submodule status --recursive
    qcc -V
    [[ -f adoption/Ref/CMakeLists.txt ]] || bash scripts/import-ref.sh
    cd adoption
    if [[ ! -f "$build_dir/CMakeCache.txt" ]]; then
        fprime-util generate qnx-x86_64 --ut --disable-sanitizers --build-cache "$build_dir" \
            -DFPRIME_ENABLE_FRAMEWORK_UTS=ON -DFPRIME_ENABLE_AUTOCODER_UTS=OFF \
            -DFPRIME_ENABLE_UT_COVERAGE=OFF
    fi
    cmake --build "$build_dir" --parallel "$jobs" --target "${suites[@]}" -- -k 0
) >"$run_dir/build.log" 2>&1 || fail "see $run_dir/build.log"

guest=""
remote_dir=""
booted=0
cleanup() {
    if [[ -n "$remote_dir" ]]; then
        ssh "${ssh_opts[@]}" "root@$guest" "rm -r '$remote_dir'" +            >>"$run_dir/cleanup.log" 2>&1 || true
    fi
    if (( booted )) && qnx_vm_running "$image_dir"; then
        (cd "$image_dir" && mkqnximage --stop) >>"$run_dir/cleanup.log" 2>&1 || true
    fi
}
trap cleanup EXIT

qnx_vm_running "$image_dir" || booted=1
qnx_vm_start "$image_dir" "$run_dir/vm-boot.log" || fail "see $run_dir/vm-boot.log"
guest="$(qnx_vm_find_guest "$image_dir" "${ssh_opts[@]}")" || fail 'QNX guest is unreachable'
target="$(ssh "${ssh_opts[@]}" "root@$guest" 'uname -a')"
[[ "$target" == QNX* ]] || fail "unexpected target platform: $target"
printf '%s\n' "$target" | tee "$run_dir/target-uname.txt"

guest_dir="/tmp/fprime-osal-${run_dir##*.}"
ssh "${ssh_opts[@]}" "root@$guest" "mkdir '$guest_dir'"
remote_dir="$guest_dir"

summary="$run_dir/summary.tsv"
printf 'suite\tstatus\tpassed\tfailed\tskipped\texit_code\n' >"$summary"
result=0
for suite in "${suites[@]}"; do
    log="$run_dir/$suite.log"
    rc=0
    # The default QNX image has a small data partition. Transfer one executable at a time.
    if scp -q "${ssh_opts[@]}" "$build_dir/bin/qnx-x86_64/$suite" "root@$guest:$remote_dir/" >"$log" 2>&1; then
        timeout -k 5s "${seconds}s" ssh "${ssh_opts[@]}" "root@$guest" \
            "cd '$remote_dir' && ./$suite --gtest_color=no" >>"$log" 2>&1 || rc=$?
    else
        rc=$?
    fi
    ssh "${ssh_opts[@]}" "root@$guest" "rm -f '$remote_dir/$suite'" >>"$log" 2>&1 || result=1
    read -r passed failed skipped < <(awk '
        $1 == "[" && $3 == "]" && $4 ~ /^[0-9]+$/ {
            if ($2 == "PASSED") passed = $4
            if ($2 == "FAILED") failed = $4
            if ($2 == "SKIPPED") skipped = $4
        }
        END { print passed+0, failed+0, skipped+0 }
    ' "$log")
    status=FAIL
    if (( rc == 0 && failed == 0 && passed > 0 )); then
        status=PASS
    elif (( rc == 0 && failed == 0 && skipped > 0 )); then
        status=SKIP
    else
        result=1
    fi
    printf '%s\t%s\t%d\t%d\t%d\t%d\n' "$suite" "$status" "$passed" "$failed" "$skipped" "$rc" |
        tee -a "$summary"
done
printf 'LocklessPriorityQueueTsanTest\tSKIP\t-\t-\t-\t-\n' | tee -a "$summary"
printf 'Cpu native\tUNSUPPORTED\t-\t-\t-\t-\nMemory native\tUNSUPPORTED\t-\t-\t-\t-\n' | tee -a "$summary"
printf 'Linux-only Task cases\tUNSUPPORTED\t-\t-\t-\t-\n' | tee -a "$summary"
exit "$result"
