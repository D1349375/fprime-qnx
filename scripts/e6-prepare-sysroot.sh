#!/usr/bin/env bash
# Build the x86-64 E6 sysroot with public APKs and the installed QNX SDP.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/e6-prepare-sysroot.sh EMPTY_DIRECTORY

Source QNX SDP 8.0.6 and put Linux apk-tools 3.x on PATH first.
The sysroot links to the local SDK and keeps the verified APK overlays.
EOF
}

if [[ $# -eq 1 && ( "$1" == -h || "$1" == --help ) ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 || -z "$1" ]]; then
    usage >&2
    exit 2
fi
: "${QNX_TARGET:?Source the installed QNX SDP 8.0.6 first}"
sdk=$(cd "$QNX_TARGET" && pwd -P)
if [[ ! -d "$sdk/x86_64/usr/lib" || ! -d "$sdk/usr/include" ]]; then
    echo 'The installed SDK must include x86-64 libraries and headers.' >&2
    exit 2
fi
for command in apk curl tar sha256sum; do
    command -v "$command" >/dev/null || { printf 'Required tool is missing: %s\n' "$command" >&2; exit 2; }
done

mkdir -p -- "$1"
sysroot=$(cd "$1" && pwd -P)
shopt -s nullglob dotglob
entries=("$sysroot"/*)
shopt -u nullglob dotglob
if (( ${#entries[@]} != 0 )); then
    printf 'The sysroot directory must be empty: %s\n' "$sysroot" >&2
    exit 2
fi

archives="$sysroot/.e6-apks"
repositories=https://repo.oss.qnx.com/8.0.3
mkdir -p "$archives" "$sysroot/etc/apk/keys"
curl --fail --silent --show-error --location --retry 2 \
    https://repo.oss.qnx.com/keys/qnxosd.rsa.pub -o "$sysroot/etc/apk/keys/qnxosd.rsa.pub"
printf '%s\n' "$repositories/extra" "$repositories/core" >"$sysroot/etc/apk/repositories"
apk --root "$sysroot" --arch x86_64 --usermode add --initdb --no-scripts
apk --root "$sysroot" --arch x86_64 update
apk --root "$sysroot" --arch x86_64 --usermode add --no-scripts \
    mlpack-dev=4.7.0-r0 armadillo-dev=15.2.7-r0 openblas=0.3.31-r0 \
    cereal=1.3.2-r0 ensmallen=3.11.0-r0 libc++=21.1.3-r5

# OpenBLAS's development APK also depends on the target compiler. Use
# the signed header and link files with QCC from the locally installed SDK.
openblas_dev=openblas-dev-0.3.31-r0.apk
openmp=openmp-21.1.3-r5.apk
(
    cd "$archives"
    curl --fail --silent --show-error --location --retry 2 \
        "$repositories/extra/x86_64/$openblas_dev" -o "$openblas_dev"
    curl --fail --silent --show-error --location --retry 2 \
        "$repositories/core/x86_64/$openmp" -o "$openmp"
    apk --root "$sysroot" --arch x86_64 verify "$archives/$openblas_dev" "$archives/$openmp"
    sha256sum "$openblas_dev" "$openmp" >SHA256SUMS
    tar --warning=no-unknown-keyword -xzf "$openblas_dev" --no-same-owner -C "$sysroot" \
        usr/include/openblas usr/lib/libopenblas.so usr/lib/pkgconfig/openblas.pc
    tar --warning=no-unknown-keyword -xzf "$openmp" --no-same-owner -C "$sysroot" usr/lib/libomp.so
)

cp -as "$sdk/x86_64" "$sysroot/"
cp -as "$sdk/usr/include/." "$sysroot/usr/include/"
printf 'E6 QNX sysroot: %s\n' "$sysroot"
