#!/usr/bin/env bash
# Cross-build a small mlpack FFN and compare loaded weights and scores on Linux and QNX.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/qnx-vm.sh"
fixture="$root/FprimeQnxReference/test/e6"
if [[ "${1:-}" == --help && $# == 1 ]]; then
    echo 'Usage: scripts/e6-check.sh /path/to/qnx-x86_64-apk-sysroot'
    exit 0
fi
[[ $# == 1 ]] || { echo 'Supply the QNX APK sysroot. See --help.' >&2; exit 2; }
: "${QNX_HOST:?Source the QNX SDP environment first}"
: "${QNX_TARGET:?Source the QNX SDP environment first}"
sysroot="$(cd "$1" && pwd -P)"
run="$(mktemp -d "${TMPDIR:-/tmp}/fprime-e6.XXXXXXXX")"
printf 'E6 evidence: %s\n' "$run"
if [[ ! -f "$sysroot/usr/include/mlpack.hpp" || ! -d "$sysroot/x86_64" ]]; then
    echo 'Expected the QNX x86_64 APK sysroot, including the mlpack headers' >&2
    exit 2
fi

target_pkg() {
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$sysroot/usr/lib/pkgconfig:$sysroot/lib/pkgconfig:$sysroot/usr/share/pkgconfig" \
        PKG_CONFIG_SYSROOT_DIR="$sysroot" pkg-config "$@"
}
{
    git -C "$root" rev-parse HEAD
    git -C "$root" status --short
    qcc -V
    printf 'SDP baseline=%s\nAPK sysroot=%s\n' "$QNX_TARGET" "$sysroot"
    apk --root "$sysroot" info -v
    "${CXX:-c++}" --version
    pkg-config --modversion armadillo openblas
    target_pkg --modversion armadillo openblas
    sha256sum "$fixture/ffn-smoke.cpp" "$fixture/weights.txt"
} >"$run/source.txt" 2>&1

# pkg-config returns separate compiler options. The sysroot include/library paths
# are also passed explicitly as in the QNX APK cross-compile codelab.
read -r -a host_flags <<<"$(pkg-config --cflags --libs armadillo openblas)"
# OpenBLAS publishes a Clang-specific OpenMP flag. QCC/GCC only needs
# the include and linker settings for this FFN.
read -r -a target_flags <<<"$(target_pkg --cflags-only-I --libs armadillo openblas)"
"${CXX:-c++}" -std=c++17 -O2 -DARMA_DONT_USE_OPENMP "${fixture}/ffn-smoke.cpp" \
    -o "$run/ffn-host" "${host_flags[@]}" >"$run/host-build.log" 2>&1
QNX_TARGET="$sysroot" "$QNX_HOST/usr/bin/q++" -Vgcc_ntox86_64_cxx -std=c++17 -O2 \
    -D_QNX_SOURCE -DARMA_DONT_USE_OPENMP -I"$sysroot/usr/include" -L"$sysroot/usr/lib" \
    -Wl,-rpath-link,"$sysroot/usr/lib" "$fixture/ffn-smoke.cpp" -o "$run/ffn-qnx" "${target_flags[@]}" >"$run/qnx-build.log" 2>&1

readelf -hld "$run/ffn-qnx" >"$run/qnx-elf.txt"
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 "$run/ffn-host" "$fixture/weights.txt" >"$run/host.csv"
mkdir "$run/runtime"
needed() {
    readelf -d "$1" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}
stage_runtime() {
    local entry candidate found
    for entry in $(needed "$1"); do
        [[ "$entry" =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
        case "$entry" in
            libc.so.*|libm.so.*|libgcc_s.so.*|libc++.so.*|libc++abi.so.*) continue ;;
        esac
        [[ ! -e "$run/runtime/$entry" ]] || continue
        found=
        for candidate in "$sysroot/usr/lib/$entry" "$sysroot/lib/$entry"; do
            if [[ -f "$candidate" ]]; then
                found="$candidate"
                break
            fi
        done
        if [[ -n "$found" ]]; then
            cp -L "$found" "$run/runtime/$entry"
            stage_runtime "$run/runtime/$entry"
        else
            printf 'Resolve from QNX guest image: %s\n' "$entry" >>"$run/runtime-from-image.txt"
        fi
    done
}
stage_runtime "$run/ffn-qnx"
find "$run/runtime" -type f -print0 | sort -z | xargs -0 -r sha256sum >"$run/runtime.sha256"
sha256sum "$run/ffn-host" "$run/ffn-qnx" >"$run/binaries.sha256"

image="${QNX_IMAGE_DIR:-$run/image}"
key="${QNX_SSH_KEY:-$run/ssh/id_ed25519}"
if [[ -z "${QNX_IMAGE_DIR:-}" ]]; then
    mkdir -m 700 "$run/ssh"
    mkdir "$image"
    if [[ ! -f "$key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    qnx_vm_build_image "$image" fprime-e6 "$key.pub" --data-size=128 >"$run/image.log" 2>&1
else
    image="$(cd "$image" && pwd -P)"
fi
ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
started=0
target=
remote=
cleanup() {
    if [[ "$remote" =~ ^/tmp/fprime-e6\.[a-zA-Z0-9]+$ ]]; then
        ssh "${ssh_opts[@]}" "$target" "rm -r '$remote'" >>"$run/cleanup.log" 2>&1 || true
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
guest="$(qnx_vm_find_guest "$image" "${ssh_opts[@]}")"
target="root@$guest"
ssh "${ssh_opts[@]}" "$target" uname -a | tee "$run/target-uname.txt"
grep -q '^QNX.*x86' "$run/target-uname.txt"
remote="$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/fprime-e6.XXXXXXXX')"
[[ "$remote" =~ ^/tmp/fprime-e6\.[a-zA-Z0-9]+$ ]]
scp -q "${ssh_opts[@]}" "$run/ffn-qnx" "$fixture/weights.txt" "$target:$remote/"
scp -q -r "${ssh_opts[@]}" "$run/runtime" "$target:$remote/"
timeout 30s ssh "${ssh_opts[@]}" "$target" "cd '$remote' &&
    LD_LIBRARY_PATH='$remote/runtime' OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 ./ffn-qnx weights.txt" \
    >"$run/qnx.csv" 2>"$run/qnx-stderr.log"
ssh "${ssh_opts[@]}" "$target" "cd '$remote' && LD_LIBRARY_PATH='$remote/runtime' ldd ./ffn-qnx" \
    >"$run/qnx-ldd.txt" 2>&1
python3 "$fixture/check-scores.py" "$run/host.csv" "$run/qnx.csv" "$fixture/weights.txt" | tee "$run/summary.txt"
