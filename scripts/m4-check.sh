#!/usr/bin/env bash
# Freeze a trained FFN, replay held-out data on both systems, then run the ADCS comparison.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$root/scripts/qnx-vm.sh"
project="$root/FprimeQnxReference"
fixture="$project/test/m4"
integration="$project/test/int"

usage() {
    cat <<'EOF'
Usage: scripts/m4-check.sh QNX_APK_SYSROOT adcs-pilot|adcs
       scripts/m4-check.sh QNX_APK_SYSROOT adcs-drift-host|adcs-drift
       scripts/m4-check.sh QNX_APK_SYSROOT adcs-pair [PAIRS] (default: 10)
       scripts/m4-check.sh QNX_APK_SYSROOT opssat [OPSSAT_V2_DIR]
EOF
}
if [[ $# == 1 && $1 == --help ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 2; fi
case "$2:$#" in
    adcs-pilot:2|adcs:2|adcs-drift:2|adcs-drift-host:2|opssat:2|opssat:3) ;;
    adcs-pair:2|adcs-pair:3)
        pairs="${3:-10}"
        [[ "$pairs" =~ ^[1-9][0-9]*$ && "$pairs" == "$((pairs))" ]] || { echo 'Expected a positive pair count' >&2; exit 2; }
        ;;
    *) usage >&2; exit 2 ;;
esac
exec </dev/null
: "${QNX_HOST:?Source the QNX SDP environment first}"
: "${QNX_TARGET:?Source the QNX SDP environment first}"
sysroot="$(realpath -e "$1")"
mode="$2"
drift=false
if [[ "$mode" == adcs-drift || "$mode" == adcs-drift-host ]]; then drift=true; fi
kernel_trace="${M4_KERNEL_TRACE:-0}"
case "$mode:$kernel_trace" in
    *:0|adcs-pair:1|adcs-pilot:on-miss|adcs:on-miss|adcs-pair:on-miss) ;;
    *) echo 'Use M4_KERNEL_TRACE=1 for adcs-pair, or on-miss for an ADCS mode' >&2; exit 2 ;;
esac
if [[ "$kernel_trace" == on-miss ]]; then
    host_tracefs="$(realpath -e "${M4_HOST_TRACEFS:?Set M4_HOST_TRACEFS to a dedicated tracefs instance}")"
    if [[ -d "$host_tracefs/instances" || "$(stat -f -c %T "$host_tracefs")" != tracefs ||
          ! -w "$host_tracefs/tracing_on" || ! -w "$host_tracefs/events/sched/sched_switch/filter" ]]; then
        echo 'Expected a writable dedicated tracefs instance from scripts/m4-tracefs.sh' >&2
        exit 2
    fi
    exec {trace_lock}<"$host_tracefs"
    flock -n "$trace_lock" || { echo 'The tracefs instance is already in use' >&2; exit 2; }
fi
cycles=230
period_ns=20000000
deadline_ns=20000000
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

if ! pkg-config --exists armadillo openblas; then
    echo 'pkg-config cannot find the host Armadillo and OpenBLAS packages used for the Linux replay.' >&2
    echo 'Install them, or set PKG_CONFIG_PATH (and LD_LIBRARY_PATH) to an isolated host package root.' >&2
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
    uname -sr
    qcc -V
    qemu-system-x86_64 --version
    for package in "$QNX_TARGET"/../../.packages/metadata/com.qnx.qnx800*/*/; do
        if [[ -d "$package" ]]; then printf 'SDP package=%s\n' "${package#*/metadata/}"; fi
    done
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
    if "$drift"; then
        schema=adcs-drift
        "$run/generate-adcs" drift >"$training/adcs.csv"
    else
        "$run/generate-adcs" >"$training/adcs.csv"
    fi
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
host_status=0
"$run/replay-host" "$schema" "$training/model.txt" "$training/input.csv" \
    >"$training/host.csv" 2>"$training/host-stderr.log" || host_status=$?
if "$drift"; then
    sha256sum "$training"/{adcs.csv,calibration.json} "$training"/calibration/{model.txt,input.csv,expected.csv} \
        >>"$training/input.sha256"
    "$run/replay-host" "$schema" "$training/model.txt" "$training/calibration/input.csv" \
        >"$training/calibration/host.csv" 2>"$training/calibration/host-stderr.log"
    "$python" "$fixture/compare.py" --host-only "$training/calibration" | tee "$training/calibration/host-summary.txt"
    "$python" "$fixture/compare.py" --host-only "$training" | tee "$training/host-summary.txt"
    [[ "$host_status" == 0 ]]
    if [[ "$mode" == adcs-drift-host ]]; then exit 0; fi
    drift_cutoff="$("$python" -c 'import json, sys; print(json.load(open(sys.argv[1]))["fdir"]["cutoff"])' \
        "$training/calibration.json")"
fi

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
            timeout -k 2s 8s ssh "${ssh_opts[@]}" "$target" "rm -f ${guest_logs[*]}" >>"$run/cleanup.log" 2>&1 || true
        fi
        timeout -k 2s 8s ssh "${ssh_opts[@]}" "$target" "rm -r '$remote'" >>"$run/cleanup.log" 2>&1 || true
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
guest_logs+=("/dev/shmem/fprime-m3-crash-${remote##*.}")
scp -q "${ssh_opts[@]}" "$run"/target-bin/* "$training"/{model.txt,input.csv} "$target:$remote/"
scp -q -r "${ssh_opts[@]}" "$run/runtime" "$target:$remote/"
for file in model.txt input.csv; do
    ssh "${ssh_opts[@]}" "$target" "cat '$remote/$file'" | cmp -s "$training/$file" -
done
target_environment="LD_LIBRARY_PATH='$remote/runtime' OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1"

if "$drift"; then
    scp -q "${ssh_opts[@]}" "$training/calibration/input.csv" "$target:$remote/calibration.csv"
    ssh "${ssh_opts[@]}" "$target" "cat '$remote/calibration.csv'" | cmp -s "$training/calibration/input.csv" -
    timeout -k 5s 45s ssh "${ssh_opts[@]}" "$target" \
        "$target_environment '$remote/m4-replay' '$schema' '$remote/model.txt' '$remote/calibration.csv'" \
        >"$training/calibration/qnx.csv" 2>"$training/calibration/qnx-stderr.log"
    "$python" "$fixture/compare.py" "$training/calibration" | tee "$training/calibration/summary.txt"
fi

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

target_runner=run-m3-target.sh
trace_files=()
if [[ "$kernel_trace" != 0 ]]; then
    target_runner=run-m3-traced.sh
    trace_files=(trace.kev trace-anchor.txt trace-status.txt tracelogger.log trace-control.log)
    qcc -Vgcc_ntox86_64 -std=c11 -Wall -Wextra "$integration/trace-control.c" -o "$run/trace-control" \
        >"$run/trace-build.log" 2>&1 || { cat "$run/trace-build.log" >&2; exit 1; }
    sha256sum "$run/trace-control" "$sdk/usr/sbin/tracelogger" "$sdk/lib/libtracelog.so.1" >>"$run/binaries.sha256"
    scp -q "${ssh_opts[@]}" "$run/trace-control" "$sdk/usr/sbin/tracelogger" \
        "$integration/run-m3-traced.sh" "$target:$remote/"
    scp -q "${ssh_opts[@]}" "$sdk/lib/libtracelog.so.1" "$target:$remote/runtime/"
    guest_logs+=("/dev/shmem/fprime-m3-${remote##*.}.kev")
fi

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
    local run_id="$1" seed="$2" group="$3" scenario="$4" advisor="$5" repair="${6:-restart}"
    local round="$run/$run_id" rc=0 timing=0 assessment=0 verdict=PASS name
    local transfers=() command=() capture_files=()
    echo "Running $run_id on QNX"
    mkdir "$round"
    printf '%s\n' "run_id=$run_id" "seed=$seed" "group=$group" "scenario=$scenario" "advisor=$advisor" \
        "repair=$repair" "kernel_trace=$kernel_trace" "cycles=$cycles" "period_ns=$period_ns" "deadline_ns=$deadline_ns" 'freshness_ns=250000000' \
        'fallback_limit_ns=300000000' 'q1_rejoin_limit_ns=1800000000' 'min_warmup_cycles=40' \
        'injection_cycle=55' 'angle_limit_deg=2' 'stable_cycles=20' 'exit_observer=procmgr' \
        'workload=seeded-adcs' 'trace_storage=qnx-shmem' 'crash_signal=SIGKILL' 'slm_rate=2/min' \
        'slm_backoff_s=1' >"$round/config.txt"
    command=(ssh "${ssh_opts[@]}" "$target"
        "$target_environment sh '$remote/$target_runner' '$remote' '$scenario' '$repair' '$seed' '$advisor'")
    if "$drift"; then
        printf 'drift_cutoff=%s\n' "$drift_cutoff" >>"$round/config.txt"
        command[-1]+=" '$drift_cutoff'"
    fi
    if [[ "$kernel_trace" == on-miss ]]; then
        command[-1]="M4_TRACE_WATCH=1 ${command[-1]}"
        command=("$python" "$integration/watch-m4.py" "$host_tracefs" "$round" "$qemu_pid" "$image"
            "$cycles" "$period_ns" "$deadline_ns" "${command[@]}")
    fi
    timeout -k 5s 28s "${command[@]}" >"$round/target.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$round/target-status.txt"
    for name in "${files[@]}"; do transfers+=("$target:$remote/$name"); done
    local capture=0 wait_limit
    if "$drift"; then
        # Collect the raw files before the next scenario can overwrite them.
        printf 'timeout\texit\n' >"$round/capture-status.tsv"
        for wait_limit in 15s 25s; do
            capture=0
            timeout -k 2s "$wait_limit" scp -q "${ssh_opts[@]}" "${transfers[@]}" "$round/" 2>>"$round/target.log" || capture=$?
            printf '%s\t%s\n' "$wait_limit" "$capture" >>"$round/capture-status.tsv"
            if (( capture == 0 )); then break; fi
        done
    else
        timeout -k 2s 10s scp -q "${ssh_opts[@]}" "${transfers[@]}" "$round/" 2>>"$round/target.log" || true
    fi
    if [[ "$kernel_trace" != 0 ]]; then
        capture_files=("${trace_files[@]}")
        if [[ "$kernel_trace" == on-miss ]]; then
            if [[ -f "$round/host-sched-before.txt" ]]; then
                capture_files+=(trace-trigger.txt)
            elif ((rc == 0)); then
                capture_files=(trace-status.txt)
            fi
        fi
        for name in "${capture_files[@]}"; do
            timeout -k 2s 6s scp -q "${ssh_opts[@]}" "$target:$remote/$name" "$round/$name" 2>>"$round/target.log" || true
        done
        if ! grep -Fxq 'wait_exit=0 before_exit=0 after_exit=0 stop_exit=0 tracelogger_exit=0' "$round/trace-status.txt" ||
           { [[ "${capture_files[0]}" == trace.kev ]] && [[ ! -s "$round/trace.kev" ]]; } ||
           { [[ -f "$round/host-sched-before.txt" ]] && [[ ! -s "$round/trace-trigger.txt" ]]; }; then
            printf 'Incomplete ring trace for %s\n' "$run_id" >&2
            result=1
        fi
    fi
    "$python" "$integration/check-m3.py" "$round" >"$round/timing.txt" 2>&1 || timing=$?
    local assessor=assess-adcs.py
    if "$drift"; then assessor=assess-drift.py; fi
    "$python" "$fixture/$assessor" "$training" "$round" >"$round/adcs.json" 2>"$round/adcs.err" || assessment=$?
    if (( timing == 2 )) || { "$drift" && (( timing == 0 && (assessment == 2 || capture != 0) )); }; then
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
    local seed="$1" scenario=recovery fault=bias
    if "$drift"; then scenario=drift; fault=drift; fi
    if (( seed % 2 == 0 )); then
        run_scenario "$seed-learned-nominal" "$seed" normal normal learned
        run_scenario "$seed-fdir-nominal" "$seed" fdir_normal normal fdir
        run_scenario "$seed-learned-$fault" "$seed" recovery "$scenario" learned
        run_scenario "$seed-fdir-$fault" "$seed" fdir_recovery "$scenario" fdir
    else
        run_scenario "$seed-fdir-nominal" "$seed" fdir_normal normal fdir
        run_scenario "$seed-learned-nominal" "$seed" normal normal learned
        run_scenario "$seed-fdir-$fault" "$seed" fdir_recovery "$scenario" fdir
        run_scenario "$seed-learned-$fault" "$seed" recovery "$scenario" learned
    fi
}

if [[ "$mode" == adcs-pair ]]; then
    printf 'pair\tseed\tfirst\tq1\tq2\tslm_config\n' >"$run/pairs.tsv"
    for ((pair = 1; pair <= pairs; ++pair)); do
        seed=$((3001 + (pair - 1) % 4))
        block="$(printf '%03d' "$pair")"
        groups=(q1 q2)
        if (( pair % 2 == 0 )); then groups=(q2 q1); fi
        for group in "${groups[@]}"; do
            repair=restart
            if [[ "$group" == q2 ]]; then repair=none; fi
            run_scenario "$block-$group" "$seed" "$group" crash learned "$repair"
        done
        q1="$block-q1"
        q2="$block-q2"
        config_status=PASS
        # As in M3, verify that the advisor repair mode is the only XML difference.
        if ! grep -Fq '<SLM:repair backoff="1">restart</SLM:repair>' "$run/$q1/m3-slm.xml" ||
           ! grep -Fq '<SLM:repair backoff="1">none</SLM:repair>' "$run/$q2/m3-slm.xml" ||
           ! sed 's/backoff="1">none</backoff="1">restart</' "$run/$q2/m3-slm.xml" |
                cmp -s "$run/$q1/m3-slm.xml" -; then
            config_status=FAIL
            result=1
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$block" "$seed" "${groups[0]}" "$q1" "$q2" "$config_status" \
            >>"$run/pairs.tsv"
    done
elif [[ "$mode" == adcs-drift ]]; then
    for seed in 3101 3102 3103 3104 3105 3106 3107 3108; do run_seed "$seed"; done
    "$python" "$fixture/assess-drift.py" --pairs "$run" >"$run/drift-pairs.json" || result=1
    printf 'ADCS slow drift pairs: %s\n' "$run/drift-pairs.json"
elif [[ "$mode" == adcs-pilot ]]; then
    run_seed 2001
    run_scenario 2001-q1-01 2001 q1 crash learned
else
    for seed in 3001 3002 3003 3004; do run_seed "$seed"; done
    for ((round = 1; round <= 10; ++round)); do
        seed=$((3001 + (round - 1) % 4))
        run_scenario "$(printf '%s-q1-%02d' "$seed" "$round")" "$seed" q1 crash learned
    done
fi
if [[ "$mode" == adcs-pair ]]; then
    "$python" "$fixture/fault-report.py" "$run" >"$run/fault-report.md" || result=1
    printf 'ADCS fault benchmark report: %s\n' "$run/fault-report.md"
fi
cat "$run/results.tsv"
printf 'M4 ADCS results: %s\n' "$run/results.tsv"
exit "$result"
