#!/usr/bin/env bash
# Freeze a trained FFN, replay held-out data on both systems, then run the ADCS comparison.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$root/scripts/qnx-vm.sh"
project="$root/FprimeQnxReference"
fixture="$project/test/m4"
integration="$project/test/int"

usage() {
    echo 'Usage: scripts/m4-check.sh QNX_APK_SYSROOT adcs-pilot|adcs|opssat [OPSSAT_V2_DIR]'
}
if [[ $# == 1 && $1 == --help ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 2; fi
case "$2:$#" in adcs-pilot:2|adcs:2|opssat:2|opssat:3) ;; *) usage >&2; exit 2 ;; esac
exec </dev/null
: "${QNX_HOST:?Source the QNX SDP environment first}"
: "${QNX_TARGET:?Source the QNX SDP environment first}"
sysroot="$(realpath -e "$1")"
mode="$2"
sdk="$QNX_TARGET/x86_64"
python="${M4_PYTHON:-python3}"
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1

outside_repo() {
    if [[ "$1" == "$root" || "$1" == "$root/"* ]]; then
        printf 'Use a directory outside the repository: %s\n' "$1" >&2
        exit 2
    fi
}
base="$(realpath -e "${TMPDIR:-/tmp}")"
outside_repo "$base"
run="$(mktemp -d "$base/fprime-m4.XXXXXXXX")"
printf 'M4 evidence: %s\n' "$run"
cache="$(realpath -m "${M4_QNX_BUILD_CACHE:-$run/build-qnx}")"
outside_repo "$cache"
if [[ ! -r "$sysroot/usr/include/mlpack.hpp" || ! -r "$sysroot/.e6-apks/SHA256SUMS" ]]; then
    echo 'Expected an E6 QNX x86-64 APK sysroot with its signed package manifest' >&2
    exit 2
fi

host_includes=()
if [[ -n "${E6_HOST_MLPACK_INCLUDE:-}" ]]; then
    host_includes=(-I "$E6_HOST_MLPACK_INCLUDE")
fi
{
    git -C "$root" rev-parse HEAD
    git -C "$root" status --short
    git -C "$root" submodule status --recursive
    cat /etc/os-release
    qcc -V
    "${CXX:-c++}" --version
    pkg-config --modversion armadillo openblas
    grep -E '^#define MLPACK_VERSION_(MAJOR|MINOR|PATCH)' \
        "$sysroot/usr/include/mlpack/core/util/version.hpp"
    printf 'SDP=%s\nAPK sysroot=%s\n' "$QNX_TARGET" "$sysroot"
    grep -E '^(P|V):' "$sysroot/lib/apk/db/installed"
    cat "$sysroot/.e6-apks/SHA256SUMS"
    "$python" -m pip freeze
} >"$run/source.txt" 2>&1
"$python" -c 'import numpy, sklearn' || { echo 'Install test/m4/requirements.txt with M4_PYTHON' >&2; exit 2; }

mkdir "$run/replay"
training="$run/replay"
pilot=()
if [[ "$mode" == opssat ]]; then
    schema=opssat-segment
    if [[ $# == 3 ]]; then
        data="$(realpath -e "$3")"
        outside_repo "$data"
    else
        data="$run/opssat-source"
        mkdir "$data"
        for file in LICENSE dataset.csv segments.csv modeling_examples.ipynb; do
            curl --fail --silent --show-error --location --retry 2 \
                "https://zenodo.org/records/15108715/files/$file?download=1" -o "$data/$file"
        done
        curl --fail --silent --show-error --location --retry 2 \
            'https://zenodo.org/api/records/15108715' -o "$data/record.json"
    fi
    sha256sum "$data"/{dataset.csv,segments.csv,LICENSE,modeling_examples.ipynb,record.json} >"$run/opssat.sha256"
else
    schema=adcs-bias
    "${CXX:-c++}" -std=c++14 -O2 -Wall -Wextra -Werror -pedantic -I"$project" \
        "$fixture/generate-adcs.cpp" -o "$run/generate-adcs"
    "$run/generate-adcs" >"$training/adcs.csv"
    data="$training/adcs.csv"
    if [[ "$mode" == adcs-pilot ]]; then pilot=(--pilot); fi
fi
"$python" "$fixture/train.py" "$schema" "$data" "$training" "${pilot[@]}" \
    >"$training/training.json" 2>"$training/training.log" || { cat "$training/training.log" >&2; exit 1; }
sha256sum "$training"/{model.txt,input.csv,expected.csv,split.csv} >"$training/input.sha256"

read -r -a host_flags <<<"$(pkg-config --cflags --libs armadillo openblas)"
"${CXX:-c++}" -std=c++17 -O2 -DARMA_DONT_USE_OPENMP -I"$project" "${host_includes[@]}" \
    "$project/MlDeployment/Ffn.cpp" "$fixture/replay.cpp" -o "$run/replay-host" "${host_flags[@]}" \
    >"$run/host-build.log" 2>&1 || { tail -45 "$run/host-build.log" >&2; exit 1; }
targets=(m4-replay)
if [[ "$mode" != opssat ]]; then targets+=(FlightSW MlAdvisor); fi
(
    cd "$project"
    if [[ ! -f "$cache/CMakeCache.txt" ]]; then
        fprime-util generate qnx-x86_64 --build-cache "$cache" -DFPRIME_QNX_M4_SYSROOT="$sysroot" \
            -DFPRIME_INSTALL_STATIC_LIBRARIES=OFF
    elif ! grep -Fxq "FPRIME_QNX_M4_SYSROOT:PATH=$sysroot" "$cache/CMakeCache.txt" ||
         ! grep -Fxq "CMAKE_HOME_DIRECTORY:INTERNAL=$project" "$cache/CMakeCache.txt"; then
        echo "The external build cache is configured for a different source or sysroot" >&2
        exit 2
    fi
    DESTDIR="$run/install" cmake --build "$cache" --parallel "${BUILD_JOBS:-2}" --target "${targets[@]}"
) >"$run/qnx-build.log" 2>&1 || { tail -45 "$run/qnx-build.log" >&2; exit 1; }
mkdir "$run/target-bin"
for name in "${targets[@]}"; do
    cp "$cache/bin/qnx-x86_64/$name" "$run/target-bin/"
    readelf -hld "$run/target-bin/$name" >"$run/$name.elf.txt"
done
mkdir "$run/runtime"
# The E6 overlay supplies these SONAMEs. The guest supplies the SDP C/C++ runtime.
for name in libarmadillo.so.15 libopenblas.so.0 libomp.so; do
    cp -L "$sysroot/usr/lib/$name" "$run/runtime/$name"
done
sha256sum "$run"/runtime/* "$run"/target-bin/* "$run/replay-host" >"$run/binaries.sha256"

image="$run/image"
key="$run/ssh/id_ed25519"
mkdir -m 700 "$run/ssh"
mkdir "$image"
ssh-keygen -q -t ed25519 -N '' -f "$key"
qnx_vm_build_image "$image" fprime-m4 "$key.pub" --data-size=256 >"$run/image.log" 2>&1
cp "$image/output/options" "$run/image-options.txt"
find -L "$image/output" -maxdepth 1 -type f \
    \( -name '*.img' -o -name '*.ifs' -o -name '*.iso' -o -name '*.qcow2' -o -name '*.raw' \
       -o -name '*.vmdk' -o -name 'ifs.bin' -o -name 'disk-qemu' \) \
    -print0 | sort -z | xargs -0 -r sha256sum >"$run/image.sha256"
[[ -s "$run/image.sha256" ]]

ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$run/known_hosts")
target=
remote=
guest_logs=()
cleanup() {
    if [[ "$remote" =~ ^/tmp/fprime-m3\.[a-zA-Z0-9]+$ ]]; then
        if (( ${#guest_logs[@]} )); then
            ssh "${ssh_opts[@]}" "$target" "rm -f ${guest_logs[*]}" >>"$run/cleanup.log" 2>&1 || true
        fi
        ssh "${ssh_opts[@]}" "$target" "rm -r '$remote'" >>"$run/cleanup.log" 2>&1 || true
    fi
    if qnx_vm_running "$image"; then
        (cd "$image" && mkqnximage --stop) >>"$run/cleanup.log" 2>&1 || true
    fi
}
trap cleanup EXIT
qnx_vm_start "$image" "$run/guest-boot.log"
qemu_pid="$(cat "$image/output/qemu.pid")"
tr '\0' '\n' <"/proc/$qemu_pid/cmdline" >"$run/qemu-argv.txt"
guest="$(qnx_vm_find_guest "$image" "${ssh_opts[@]}")"
target="root@$guest"
ssh "${ssh_opts[@]}" "$target" uname -a | tee "$run/target-uname.txt"
grep -q '^QNX.*x86' "$run/target-uname.txt"
created="$(ssh "${ssh_opts[@]}" "$target" 'mktemp -d /tmp/fprime-m3.XXXXXXXX')"
[[ "$created" =~ ^/tmp/fprime-m3\.[a-zA-Z0-9]+$ ]]
remote="$created"
scp -q "${ssh_opts[@]}" "$run"/target-bin/* "$training"/{model.txt,input.csv} "$target:$remote/"
scp -q -r "${ssh_opts[@]}" "$run/runtime" "$target:$remote/"
for file in model.txt input.csv; do
    ssh "${ssh_opts[@]}" "$target" "cat '$remote/$file'" | cmp -s "$training/$file" -
done
target_environment="LD_LIBRARY_PATH='$remote/runtime' OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1"

host_status=0
"$run/replay-host" "$schema" "$training/model.txt" "$training/input.csv" \
    >"$training/host.csv" 2>"$training/host-stderr.log" || host_status=$?
qnx_status=0
timeout -k 5s 60s ssh "${ssh_opts[@]}" "$target" \
    "cd '$remote' && $target_environment ./m4-replay '$schema' model.txt input.csv" \
    >"$training/qnx.csv" 2>"$training/qnx-stderr.log" || qnx_status=$?
printf 'linux_exit=%s qnx_exit=%s\n' "$host_status" "$qnx_status" | tee "$training/status.txt"
loader_status=0
for name in "${targets[@]}"; do
    ssh "${ssh_opts[@]}" "$target" "cd '$remote' && $target_environment ldd './$name'" \
        >"$run/$name.ldd.txt" 2>&1 || loader_status=1
done
"$python" "$fixture/compare.py" "$training" | tee "$training/summary.txt"
[[ "$host_status" == 0 && "$qnx_status" == 0 && "$loader_status" == 0 ]]
if [[ "$mode" == opssat ]]; then
    printf 'M4 OPSSAT-AD results: %s\n' "$training/summary.txt"
    exit 0
fi

qcc -Vgcc_ntox86_64 -D_QNX_SOURCE -std=c11 -Wall -Wextra "$integration/watch-death.c" -o "$run/watch-death" \
    >"$run/death-watch-build.log" 2>&1
sha256sum "$run/watch-death" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" \
    "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" >>"$run/binaries.sha256"
ssh "${ssh_opts[@]}" "$target" "mkdir '$remote/slm-libs'"
scp -q "${ssh_opts[@]}" "$run/watch-death" "$sdk/usr/sbin/slm" "$sdk/bin/slmctl" \
    "$project/qnx/m3-slm.xml.in" "$integration/run-m3-target.sh" "$target:$remote/"
scp -q "${ssh_opts[@]}" "$sdk/usr/lib/libexpat.so.2" "$sdk/lib/libsecpol.so.1" "$sdk/lib/libqh.so.1" \
    "$target:$remote/slm-libs/"

result=0
printf 'run_id\tgroup\tseed\ttarget_exit\ttiming_exit\tadcs_exit\tverdict\n' >"$run/results.tsv"
files=(flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log death.csv death.log)
# Keep trace writes off the virtual disk while retaining the same application and SLM paths.
stage_logs="set -e"
for name in "${files[@]}"; do
    path="/dev/shmem/fprime-m4-${remote##*.}-$name"
    guest_logs+=("$path")
    stage_logs+=$'\n'": > '$path'; ln -s '$path' '$remote/$name'"
done
ssh "${ssh_opts[@]}" "$target" "$stage_logs" >"$run/trace-staging.log" 2>&1 ||
    { cat "$run/trace-staging.log" >&2; exit 1; }
files+=(m3-slm.xml)
run_scenario() {
    local run_id="$1" seed="$2" group="$3" scenario="$4" advisor="$5"
    local round="$run/$run_id" rc=0 timing=0 assessment=0 verdict=PASS name
    local transfers=()
    echo "Running $run_id on QNX"
    mkdir "$round"
    printf '%s\n' "run_id=$run_id" "seed=$seed" "group=$group" "scenario=$scenario" "advisor=$advisor" \
        'repair=restart' 'cycles=230' 'period_ns=20000000' 'deadline_ns=20000000' 'freshness_ns=250000000' \
        'fallback_limit_ns=300000000' 'q1_rejoin_limit_ns=1800000000' 'min_warmup_cycles=40' \
        'injection_cycle=55' 'angle_limit_deg=2' 'stable_cycles=20' 'exit_observer=procmgr' \
        'workload=seeded-adcs' 'trace_storage=qnx-shmem' 'crash_signal=SIGKILL' 'slm_rate=2/min' \
        'slm_backoff_s=1' >"$round/config.txt"
    timeout -k 5s 28s ssh "${ssh_opts[@]}" "$target" \
        "$target_environment sh '$remote/run-m3-target.sh' '$remote' '$scenario' restart '$seed' '$advisor'" \
        >"$round/target.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$round/target-status.txt"
    for name in "${files[@]}"; do transfers+=("$target:$remote/$name"); done
    scp -q "${ssh_opts[@]}" "${transfers[@]}" "$round/" 2>>"$round/target.log" || true
    "$python" "$integration/check-m3.py" "$round" >"$round/timing.txt" 2>&1 || timing=$?
    "$python" "$fixture/assess-adcs.py" "$training" "$round" >"$round/adcs.json" 2>"$round/adcs.err" || assessment=$?
    if (( timing == 2 )); then
        verdict=INDETERMINATE
    elif (( rc || timing || assessment )); then
        verdict=FAIL
    fi
    if [[ "$verdict" != PASS ]]; then
        result=1
        cat "$round/target.log" "$round/timing.txt" "$round/adcs.err" >&2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_id" "$group" "$seed" "$rc" "$timing" "$assessment" "$verdict" >>"$run/results.tsv"
}

run_seed() {
    local seed="$1"
    if (( seed % 2 == 0 )); then
        run_scenario "$seed-learned-nominal" "$seed" normal normal learned
        run_scenario "$seed-fdir-nominal" "$seed" fdir_normal normal fdir
        run_scenario "$seed-learned-bias" "$seed" recovery recovery learned
        run_scenario "$seed-fdir-bias" "$seed" fdir_recovery recovery fdir
    else
        run_scenario "$seed-fdir-nominal" "$seed" fdir_normal normal fdir
        run_scenario "$seed-learned-nominal" "$seed" normal normal learned
        run_scenario "$seed-fdir-bias" "$seed" fdir_recovery recovery fdir
        run_scenario "$seed-learned-bias" "$seed" recovery recovery learned
    fi
}

if [[ "$mode" == adcs-pilot ]]; then
    run_seed 2001
    run_scenario 2001-q1-01 2001 q1 crash learned
else
    for seed in 3001 3002 3003 3004; do run_seed "$seed"; done
    for ((round = 1; round <= 10; ++round)); do
        seed=$((3001 + (round - 1) % 4))
        run_scenario "$(printf '%s-q1-%02d' "$seed" "$round")" "$seed" q1 crash learned
    done
fi
cat "$run/results.tsv"
printf 'M4 ADCS results: %s\n' "$run/results.tsv"
exit "$result"
