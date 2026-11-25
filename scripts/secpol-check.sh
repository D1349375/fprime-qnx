#!/usr/bin/env bash
# Verify the scoped policy in a dedicated x86-64 QNX guest.
set -euo pipefail
umask 077

if (( $# != 0 )); then
    echo 'Usage: scripts/secpol-check.sh (requires built qnx-x86_64 FlightSW and MlAdvisor)' >&2
    exit 2
fi
: "${QNX_TARGET:?Source the QNX SDP environment first}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/qnx-vm.sh"
project="$root/FprimeQnxReference"
sdk="$QNX_TARGET/x86_64"
artifacts="$project/build-artifacts/qnx-x86_64"
flight="$artifacts/FlightSW/bin/FlightSW"
advisor="$artifacts/MlAdvisor/bin/MlAdvisor"
test -x "$flight" && test -x "$advisor" || { echo 'Build FprimeQnxReference for qnx-x86_64 first' >&2; exit 1; }

run=$(mktemp -d "${TMPDIR:-/tmp}/fprime-secpol.XXXXXXXX")
run=$(realpath "$run")
printf 'Secpol evidence: %s\n' "$run"
image="$run/image"
key="$run/id_ed25519"
mkdir "$image"
ssh-keygen -q -t ed25519 -N '' -f "$key"
cp "$project/qnx/advisor-secpol.txt" "$run/policy.txt"
secpolcompile -o "$run/policy.bin" "$run/policy.txt" >"$run/compile.log" 2>&1 || { cat "$run/compile.log" >&2; exit 1; }
qcc -Vgcc_ntox86_64 -D_QNX_SOURCE -std=c11 -Wall -Wextra -Werror \
    "$project/test/int/gate-open-probe.c" -o "$run/gate-open-probe" >"$run/probe-build.log" 2>&1 || { cat "$run/probe-build.log" >&2; exit 1; }
git -C "$root" rev-parse HEAD >"$run/source.txt"
git -C "$root" submodule status --recursive >>"$run/source.txt"
qcc -V >>"$run/source.txt" 2>&1
sha256sum "$flight" "$advisor" "$run/policy.txt" "$run/policy.bin" "$run/gate-open-probe" >"$run/binaries.sha256"
qnx_vm_build_image "$image" fprime-secpol "$key.pub" --data-size=128 \
    --policy="$run/policy.txt" --secpol=no >"$run/image.log" 2>&1
cleanup() {
    if qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >>"$run/cleanup.log" 2>&1 || true
        local deadline=$((SECONDS + 10))
        while qnx_vm_running "$image" && (( SECONDS < deadline )); do sleep 0.2; done
        if qnx_vm_running "$image"; then
            printf 'Policy guest is still running in %s\n' "$image" >&2
        fi
    fi
}
trap cleanup EXIT
qnx_vm_start "$image" "$run/guest-boot.log"
ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
guest=$(qnx_vm_find_guest "$image" "${ssh_opts[@]}")
target="root@$guest"
ssh "${ssh_opts[@]}" "$target" uname -a | tee "$run/target-uname.txt"
remote=$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/fprime-secpol.XXXXXXXX')
[[ "$remote" =~ ^/tmp/fprime-secpol\.[[:alnum:]]+$ ]]
ssh "${ssh_opts[@]}" "$target" "mkdir '$remote/slm-libs'"
scp -q "${ssh_opts[@]}" "$flight" "$advisor" "$run/gate-open-probe" "$sdk/bin/secpolpush" \
    "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" "$project/qnx/m3-slm.xml.in" "$project/test/int/run-secpol-target.sh" \
    "$target:$remote/"
scp -q "${ssh_opts[@]}" "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" \
    "$target:$remote/slm-libs/"

status=0
timeout -k 5s 25s ssh "${ssh_opts[@]}" "$target" "sh '$remote/run-secpol-target.sh' '$remote'" \
    >"$run/target.log" 2>&1 || status=$?
for file in advisor.log advisor.err advisor-type.txt flight.log flight.err slm.log slm.xml gate-control.txt gate-denied.txt; do
    scp -q "${ssh_opts[@]}" "$target:$remote/$file" "$run/" >>"$run/transfer.log" 2>&1 || true
done
cat "$run/target.log"
exit "$status"
