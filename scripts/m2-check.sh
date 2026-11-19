#!/usr/bin/env bash
# Run the M2 dual-process timing check on a QNX x86-64 guest.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/qnx-vm.sh"
project="$root/FprimeQnxReference"
artifacts="$project/build-artifacts/qnx-x86_64"
transport="${1:-udp}"
if [[ "$transport" != udp && "$transport" != qnx && "$transport" != slm || "$#" -gt 1 ]]; then
    echo 'Usage: scripts/m2-check.sh [udp|qnx|slm]' >&2
    exit 2
fi

flight="$artifacts/FlightSW/bin/FlightSW"
advisor="$artifacts/MlAdvisor/bin/MlAdvisor"
if [[ ! -x "$flight" || ! -x "$advisor" ]]; then
    echo "Build FlightSW and MlAdvisor under $project first" >&2
    exit 1
fi

run="$(mktemp -d "$project/build-m2-check.XXXXXXXX")"
printf 'M2 evidence: %s\n' "$run"
image="${QNX_IMAGE_DIR:-$run/image}"
key="${QNX_SSH_KEY:-$run/ssh/id_ed25519}"
if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir -m 700 "$run/ssh"
    mkdir "$image"
    if [[ ! -f "$key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    qnx_vm_build_image "$image" fprime-m2 "$key.pub" --data-size=128 >"$run/image.log" 2>&1 ||
        { tail -30 "$run/image.log"; exit 1; }
else
    image="$(cd "$image" && pwd)"
fi

ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
target=
target_dir=
cleanup() {
    if [[ -n "$target_dir" ]]; then
        ssh "${ssh_opts[@]}" "$target" "rm -rf -- '$target_dir'" </dev/null || true
    fi
    if (( started )) && qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >"$run/guest-stop.log" 2>&1 || true
    fi
}
trap cleanup EXIT
if ! qnx_vm_running "$image"; then
    started=1
    qnx_vm_start "$image" "$run/guest-boot.log"
fi
guest="$(qnx_vm_find_guest "$image" "${ssh_opts[@]}")"
target="root@$guest"
ssh "${ssh_opts[@]}" "$target" uname -a >"$run/target-uname.txt"
{
    git -C "$root" rev-parse HEAD
    git -C "$root" status --short
    git -C "$root" submodule status
    sha256sum "$flight" "$advisor"
} >"$run/source.txt"

created="$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/fprime-m2.XXXXXXXX')"
if [[ ! "$created" =~ ^/tmp/fprime-m2\.[a-zA-Z0-9]+$ ]]; then
    echo "Unexpected guest work path: $created" >&2
    exit 1
fi
target_dir="$created"
files=(flight.csv flight.log advisor.log)
runner=run-target.sh
if [[ "$transport" == slm ]]; then
    runner=run-slm.sh
    sdk="${QNX_TARGET:?Source the QNX SDP environment first}/x86_64"
    ssh "${ssh_opts[@]}" "$target" "mkdir '$target_dir/slm-libs'"
    scp -q "${ssh_opts[@]}" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" "$project/qnx/m2-slm.xml.in" "$target:$target_dir/"
    scp -q "${ssh_opts[@]}" "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" \
        "$target:$target_dir/slm-libs/"
    files+=(flight.err advisor.err slm.log slm-before.log slm-after.log m2-slm.xml)
fi
scp -q "${ssh_opts[@]}" "$flight" "$advisor" "$project/test/int/$runner" "$target:$target_dir/"
status=0
timeout 40 ssh "${ssh_opts[@]}" "$target" "cd '$target_dir' && sh './$runner' '$transport'" \
    >"$run/target-run.log" 2>&1 || status=$?
for name in "${files[@]}"; do
    scp -q "${ssh_opts[@]}" "$target:$target_dir/$name" "$run/$name" || true
done
if (( status != 0 )); then
    tail -30 "$run/target-run.log"
    exit "$status"
fi
python3 "$project/test/int/check-trace.py" "$run" "$transport" | tee "$run/summary.txt"
