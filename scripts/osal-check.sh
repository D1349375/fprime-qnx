#!/usr/bin/env bash
# Cross-build the pinned upstream OSAL suites with the portability test fixes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/qnx-vm.sh"

fail() { printf 'osal-check: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    cat <<'EOF'
Usage: scripts/osal-check.sh

Source the QNX SDP 8.0 environment and activate the F Prime venv. The script
stages the test sources and provisions a fresh x86-64 QNX image with its own SSH key.
Set QNX_IMAGE_DIR and QNX_SSH_KEY to use an existing image with enough space
for the death tests. Other optional environment: QNX_KNOWN_HOSTS,
TMPDIR (parent directory for external run evidence),
OSAL_BUILD_DIR (reuse a cache for matching staged test sources),
BUILD_JOBS (default: 2), TEST_SECONDS (default: 90).
EOF
    exit 0
fi
(( $# == 0 )) || fail 'see --help for available settings'
[[ -n "${QNX_HOST:-}" && -n "${QNX_TARGET:-}" ]] || fail 'source qnxsdp-env.sh first'
command -v fprime-util >/dev/null || fail 'activate the F Prime venv first'
[[ -f "$ROOT/lib/fprime/CMakeLists.txt" && -f "$ROOT/lib/fprime/googletest/CMakeLists.txt" ]] ||
    fail 'initialize lib/fprime and its test dependency with git submodule update --init --recursive'

jobs="${BUILD_JOBS:-2}"
seconds="${TEST_SECONDS:-90}"
[[ "$jobs" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] ||
    fail 'BUILD_JOBS and TEST_SECONDS must be positive integers'

run_dir="$(realpath -e -- "$(mktemp -d "${TMPDIR:-/tmp}/fprime-qnx-osal.XXXXXXXX")")"
printf 'OSAL evidence: %s\n' "$run_dir"
build_dir="$(realpath -m -- "${OSAL_BUILD_DIR:-$run_dir/build}")"
mkdir -p -- "$(dirname -- "$build_dir")"
# Serialize runs that explicitly share a build cache.
exec 9>"${build_dir}.osal.lock"
flock -x 9
known_hosts="${QNX_KNOWN_HOSTS:-$run_dir/known_hosts}"

if [[ -n "${QNX_IMAGE_DIR:-}" ]]; then
    image_dir="$(cd "$QNX_IMAGE_DIR" && pwd -P)" || fail 'QNX image directory not found'
    key="$(realpath -e -- "${QNX_SSH_KEY:-$HOME/.ssh/qnx_vm}")" || fail 'QNX SSH key not found'
    [[ -r "$key" ]] || fail 'QNX SSH key is unreadable'
else
    image_dir="$run_dir/image"
    mkdir -- "$image_dir"
    mkdir -m 700 -- "$run_dir/ssh"
    key="$run_dir/ssh/id_ed25519"
    ssh-keygen -q -t ed25519 -N '' -f "$key"
    # QNX's dumper can write core files for intentional death-test crashes.
    qnx_vm_build_image "$image_dir" fprime-osal "$key.pub" --data-size=128 >"$run_dir/image.log" 2>&1 ||
        fail "see $run_dir/image.log"
fi
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

    # The suite changes belong to this validation build. Stage the pinned framework
    # and its test dependency without editing the source checkout's submodules.
    framework_rev=$(git rev-parse HEAD:lib/fprime)
    gtest_rev=$(git -C lib/fprime rev-parse "$framework_rev:googletest")
    patch_file="$ROOT/adoption/osal-test-portability.patch"
    source_dir="${build_dir}.sources"
    source_inputs=$(
        printf 'checkout=%s\nframework=%s\ngoogletest=%s\nqnx_host=%s\nqnx_target=%s\n' \
            "$ROOT" "$framework_rev" "$gtest_rev" "$QNX_HOST" "$QNX_TARGET"
        sha256sum adoption/{settings.ini,CMakeLists.txt,ref-qnx.patch,osal-test-portability.patch} scripts/import-ref.sh
    )
    printf '%s\n' "$source_inputs"

    if [[ -d "$source_dir" && -r "$source_dir/osal-inputs.txt" ]]; then
        [[ "$(<"$source_dir/osal-inputs.txt")" == "$source_inputs" ]] ||
            fail 'OSAL_BUILD_DIR inputs changed. Use a fresh build directory.'
    elif [[ -e "$source_dir" || -e "$build_dir/CMakeCache.txt" ]]; then
        fail 'OSAL_BUILD_DIR does not have a matching test source. Use a fresh build directory.'
    else
        staging=$(mktemp -d "${source_dir}.XXXXXXXX")
        mkdir -- "$staging/lib" "$staging/adoption" "$staging/scripts"
        git clone --quiet --local --no-checkout "$ROOT/lib/fprime" "$staging/lib/fprime"
        git -C "$staging/lib/fprime" checkout --quiet --detach "$framework_rev"
        git -C "$staging/lib/fprime" -c protocol.file.allow=always \
            -c "submodule.googletest.url=$ROOT/lib/fprime/googletest" submodule update --quiet --init -- googletest
        git -C "$staging/lib/fprime" apply --whitespace=error-all "$patch_file"
        cp -- "$ROOT/adoption/"{settings.ini,CMakeLists.txt,ref-qnx.patch} "$staging/adoption/"
        cp -- "$ROOT/scripts/import-ref.sh" "$staging/scripts/"
        ln -s -- "$ROOT/FprimeQnx" "$staging/FprimeQnx"
        bash "$staging/scripts/import-ref.sh"
        printf '%s\n' "$source_inputs" >"$staging/osal-inputs.txt"
        mv -T -- "$staging" "$source_dir"
    fi

    printf 'OSAL test source: %s\n' "$source_dir"
    if [[ -f "$build_dir/CMakeCache.txt" ]]; then
        grep -Fxq "CMAKE_HOME_DIRECTORY:INTERNAL=$source_dir/adoption" "$build_dir/CMakeCache.txt" ||
            fail 'OSAL_BUILD_DIR points to a different project. Use a fresh build directory.'
    else
        cd "$source_dir/adoption"
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
        ssh "${ssh_opts[@]}" "root@$guest" "rm -r '$remote_dir'" \
            >>"$run_dir/cleanup.log" 2>&1 || true
    fi
    if (( booted )) && qnx_vm_running "$image_dir"; then
        (cd "$image_dir" && mkqnximage --stop) >>"$run_dir/cleanup.log" 2>&1 || true
    fi
}
trap cleanup EXIT

qnx_vm_running "$image_dir" || booted=1
qnx_vm_start "$image_dir" "$run_dir/vm-boot.log" 9>&- || fail "see $run_dir/vm-boot.log"
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
