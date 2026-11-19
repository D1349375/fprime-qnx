#!/usr/bin/env bash
# Build and verify Ref from a fresh clone and a fresh QNX x86-64 image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/qnx-vm.sh"

usage() {
    cat <<'EOF'
Usage: scripts/clean-rebuild.sh [EMPTY_WORK_DIRECTORY]

Source the QNX SDP 8.0 environment and activate the F Prime venv first.
Build and VM logs remain in the work directory. With no argument, mktemp creates it.
Optional environment: FPRIME_QNX_SOURCE (default: this checkout), FPRIME_QNX_REF
(default: the clone's HEAD), BUILD_JOBS (default: 2), QNX_SSH_KEY (private key
with a matching .pub file; default: generate a key for this run).
EOF
}

fail() { printf 'clean-rebuild: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    usage
    exit 0
fi
(( $# <= 1 )) || { usage >&2; exit 2; }

[[ -n "${QNX_HOST:-}" && -n "${QNX_TARGET:-}" ]] ||
    fail 'source qnxsdp-env.sh first'
for tool in git patch qcc mkqnximage qemu-system-x86_64 fprime-util fprime-gds fprime-cli ssh scp ssh-keygen; do
    command -v "$tool" >/dev/null || fail "required tool is missing: $tool"
done
jobs="${BUILD_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_JOBS must be a positive integer'

if [[ $# -eq 1 ]]; then
    [[ -n "$1" ]] || fail 'the work directory must be a nonempty path'
    mkdir -p -- "$1"
    work_dir="$(realpath -- "$1")"
    shopt -s nullglob dotglob
    existing=("$work_dir"/*)
    shopt -u nullglob dotglob
    (( ${#existing[@]} == 0 )) || fail "work directory is not empty: $work_dir"
else
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fprime-qnx-rebuild.XXXXXXXX")"
fi

log_dir="$work_dir/logs"
checkout="$work_dir/source"
image_dir="$work_dir/image"
mkdir -- "$log_dir" "$image_dir"
printf 'Work directory and evidence: %s\n' "$work_dir"

if [[ -n "${QNX_SSH_KEY:-}" ]]; then
    key="$(realpath -e -- "$QNX_SSH_KEY")"
    [[ -r "$key" && -r "$key.pub" ]] || fail 'QNX_SSH_KEY needs a readable matching .pub file'
else
    mkdir -m 700 -- "$work_dir/ssh"
    key="$work_dir/ssh/id_ed25519"
    ssh-keygen -q -t ed25519 -N '' -f "$key"
fi

{
    git clone --no-local --no-checkout -- "${FPRIME_QNX_SOURCE:-$ROOT}" "$checkout"
    git -C "$checkout" checkout --detach "${FPRIME_QNX_REF:-HEAD}"
    git -C "$checkout" submodule update --init --recursive --jobs "$jobs"
    git -C "$checkout" show -s --format='Source commit %H'
    git -C "$checkout" submodule status --recursive
    qcc -V
} 2>&1 | tee "$log_dir/source.log"

(
    bash "$checkout/scripts/import-ref.sh"
    cd "$checkout/adoption"
    fprime-util generate qnx-x86_64
    fprime-util build qnx-x86_64 -j "$jobs"
) 2>&1 | tee "$log_dir/build.log"

(
    cd "$image_dir"
    mkqnximage --noprompt --type=qemu --arch=x86_64 --cpu=2 --ram=1536M \
        --hostname=fprime-ref --ssh-ident="$key.pub" --build
) 2>&1 | tee "$log_dir/image.log"

cleanup() {
    if qnx_vm_running "$image_dir"; then
        (cd "$image_dir" && mkqnximage --stop) >>"$log_dir/image.log" 2>&1 ||
            printf 'Could not stop validation VM in %s\n' "$image_dir" >&2
    fi
}
trap cleanup EXIT

QNX_IMAGE_DIR="$image_dir" QNX_SSH_KEY="$key" QNX_KNOWN_HOSTS="$log_dir/known_hosts" \
    bash "$checkout/scripts/ref-gds-check.sh" 2>&1 | tee "$log_dir/ref-gds.log"
printf 'PASS: clean clone, build, QNX boot and Ref/GDS check\n'
