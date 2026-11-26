#!/usr/bin/env bash
####
# math-ut-check.sh: cross-build the MathComponent tutorial's own MathSender and MathReceiver unit tests for
# qnx-x86_64 and run them on a QNX guest.
#
# Run scripts/import-math.sh first. The unit test build uses its own cache under adoption/math-tutorial.
# Environment: QNX_IMAGE_DIR and QNX_SSH_KEY to reuse a guest image, BUILD_JOBS (default 2),
#              UT_EVIDENCE_ROOT (default: TMPDIR or /tmp; must be outside the repository).
####
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/qnx-vm.sh"
[[ $# -eq 0 ]] || { echo 'Usage: scripts/math-ut-check.sh' >&2; exit 2; }

: "${QNX_TARGET:?Source the QNX SDP environment first}"
command -v fprime-util >/dev/null
project=$root/adoption/math-tutorial
[[ -r "$project/settings.ini" && -e "$project/lib/fprime/googletest/CMakeLists.txt" ]] || {
    echo 'Run scripts/import-math.sh from a checkout with lib/fprime/googletest initialized.' >&2
    exit 1
}
jobs=${BUILD_JOBS:-2}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'BUILD_JOBS must be a positive integer' >&2; exit 2; }
evidence_root=$(realpath -e "${UT_EVIDENCE_ROOT:-${TMPDIR:-/tmp}}")
case "$evidence_root/" in "$root/"*) echo 'Use an evidence directory outside the repository.' >&2; exit 2 ;; esac
run=$(mktemp -d "$evidence_root/math-ut.XXXXXXXX")
printf 'Math unit test evidence: %s\n' "$run"
fail() { printf 'FAIL %s (see %s)\n' "$*" "$run" >&2; exit 1; }

suites=(MathProject_Components_MathSender_ut_exe MathProject_Components_MathReceiver_ut_exe)
cache=$project/build-fprime-automatic-qnx-x86_64-ut
(
    cd "$project"
    git -C "$root" rev-parse HEAD
    git rev-parse HEAD
    git -C lib/fprime rev-parse HEAD
    qcc -V
    if [[ ! -f "$cache/CMakeCache.txt" ]]; then
        fprime-util generate qnx-x86_64 --ut --disable-sanitizers -DFPRIME_ENABLE_UT_COVERAGE=OFF
    fi
    cmake --build "$cache" --parallel "$jobs" --target "${suites[@]}"
) >"$run/build.log" 2>&1 || fail 'unit test build failed'

image=${QNX_IMAGE_DIR:-$run/image}
key=${QNX_SSH_KEY:-$run/id_ed25519}
ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
guest=
remote_dir=
cleanup() {
    set +e
    if [[ -n "$remote_dir" ]]; then
        ssh "${ssh_opts[@]}" "root@$guest" "rm -rf -- '$remote_dir'" </dev/null >>"$run/cleanup.log" 2>&1
    fi
    if (( started )) && qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >>"$run/cleanup.log" 2>&1
    fi
}
trap cleanup EXIT

if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir "$image"
    [[ -n "${QNX_SSH_KEY:-}" ]] || ssh-keygen -q -t ed25519 -N '' -f "$key"
    qnx_vm_build_image "$image" fprime-math-ut "$key.pub" >"$run/image.log" 2>&1 || fail 'guest image build failed'
fi
image=$(cd "$image" && pwd -P)
if ! qnx_vm_running "$image"; then
    started=1
    qnx_vm_start "$image" "$run/guest-boot.log" || fail 'could not boot the guest'
fi
guest=$(qnx_vm_find_guest "$image" "${ssh_opts[@]}") || fail 'QNX guest unavailable'
ssh "${ssh_opts[@]}" "root@$guest" uname -a </dev/null | tee "$run/target-uname.txt"
candidate=$(ssh "${ssh_opts[@]}" "root@$guest" 'mktemp -d /tmp/fprime-math-ut.XXXXXXXX' </dev/null)
[[ "$candidate" =~ ^/tmp/fprime-math-ut\.[a-zA-Z0-9]+$ ]] || fail 'invalid guest work directory'
remote_dir=$candidate

summary=$run/summary.tsv
printf 'suite\tstatus\tpassed\tfailed\texit_code\n' >"$summary"
result=0
for suite in "${suites[@]}"; do
    log=$run/$suite.log
    rc=0
    scp -q "${ssh_opts[@]}" "$cache/bin/qnx-x86_64/$suite" "root@$guest:$remote_dir/" >"$log" 2>&1 ||
        fail "copy of $suite failed"
    timeout -k 5s 120s ssh "${ssh_opts[@]}" "root@$guest" "cd '$remote_dir' && ./$suite --gtest_color=no" \
        </dev/null >>"$log" 2>&1 || rc=$?
    read -r passed failed < <(awk '
        $1 == "[" && $3 == "]" && $4 ~ /^[0-9]+$/ {
            if ($2 == "PASSED") passed = $4
            if ($2 == "FAILED") failed = $4
        }
        END { print passed+0, failed+0 }
    ' "$log")
    status=FAIL
    if (( rc == 0 && failed == 0 && passed > 0 )); then status=PASS; else result=1; fi
    printf '%s\t%s\t%d\t%d\t%d\n' "$suite" "$status" "$passed" "$failed" "$rc" | tee -a "$summary"
done
exit "$result"
