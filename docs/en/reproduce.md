
# Reproduce

Follow [Host setup](host-setup.md) for Ubuntu, KVM, the libvirt guest network and the local QNX SDP. Run target checks from an x86-64 Ubuntu shell. The exact source tested for each result appears in the [evidence index](evidence-index.md).

## Checkout and environment

Use the frozen target source for the commands below. It includes the E2 process monitor, the slow-drift comparison, the paired report and the host checks.

```bash
git clone --no-checkout https://github.com/D1349375/fprime-qnx.git
cd fprime-qnx
git checkout --detach 71fe650b3ba43e0afc77f15d8f6776c840cbffa9
git submodule update --init --recursive
git rev-parse HEAD
git submodule status --recursive
```

Activate the tools installed in [Host setup](host-setup.md#qnx-sdk-and-f-prime-tools). Use the SDK installation path on your machine. Keep the evidence and generated images outside the checkout. The commands below share this environment.

```bash
source "$HOME/qnx800/qnxsdp-env.sh"
source "$HOME/.venvs/fprime-qnx/bin/activate"
mkdir -p "$HOME/fprime-qnx-evidence"
export TMPDIR="$(mktemp -d "$HOME/fprime-qnx-evidence/run.XXXXXXXX")"
export BUILD_JOBS=2
```

## Ref and GDS (V2 and V2b)

```bash
scripts/clean-rebuild.sh
```

Expect a fresh clone, x86-64 cross-build, fresh QNX image and a successful GDS round trip. The last line reports `PASS`. Verify the source and SDK in `logs/source.log`, the guest in `logs/image.log` and the GDS probe in `logs/ref-gds.log`. `CdhCore.cmdDisp.CMD_NO_OP` produces `NoOpReceived` and `OpCodeCompleted`. The probe also receives rate group 1 telemetry. If TCP port `50000` is occupied, set `GDS_PORT` to an unused port. If the event listeners need a longer telemetry discovery window, increase `CHECK_SECONDS`. For example, `GDS_PORT=51000 CHECK_SECONDS=90 scripts/clean-rebuild.sh` uses the alternate port and a longer wait. [Ref evidence](results.md#ref-and-adcs-ground-system)

## OSAL (V1)

```bash
scripts/osal-check.sh
```

The script stages the pinned F Prime sources with the [test portability patch](../../adoption/osal-test-portability.patch), cross-builds the selected OSAL executables and runs each in a new QNX guest. Inspect `summary.tsv`, `target-uname.txt` and the per-suite logs in the printed directory. The expected skip is the test that needs `/dev/full`. The ThreadSanitizer suite and unsupported features have separate entries. [OSAL results](results.md#osal-v1)

## M2 process and transport checks

Build and install the deterministic advisor and FlightSW before running M2 or the ADCS ground check.

```bash
(
    cd FprimeQnxReference
    fprime-util generate qnx-x86_64
    fprime-util build qnx-x86_64 --jobs 2
)
scripts/m2-check.sh udp
scripts/m2-check.sh qnx
scripts/m2-check.sh slm
```

The UDP and native IPC runs exercise a full snapshot queue and advisor loss. Check the printed run directories for separate process identities, queued requests and replies, and flight output after the advisor stops. The SLM run additionally checks for a replacement advisor and a fresh session. [Transport results](results.md#deterministic-adcs)

## ADCS ground system

After the M2 build, run the ground acceptance script.

```bash
scripts/gds-check.sh
```

The script starts GDS and boots a QNX guest with FlightSW and the deterministic advisor. It sends `CMD_NO_OP` and checks both responses. The script exits an unrelated process, stops the managed advisor and checks for exactly one `ProcessDied` with the stopped advisor PID. It verifies `FdirEngaged`, a distinct SLM replacement PID, `AdvisorAccepted` with a fresh session and the ML to FDIR to ML sequence in `ControlSource`. The script reconnects GDS to the same FlightSW and checks orderly shutdown. Read `final-verdict.txt`, `sessions.csv`, `capture/` and `target/` in the printed evidence directory. [Ground event verifier](../../FprimeQnxReference/test/int/check-gds.py)

To inspect the web UI, run `scripts/gds-check.sh --ui` and open [localhost:5000](http://localhost:5000/) at the pause before the advisor stops. Open Events to see the command responses and `ProcessDied`. Check Channels for `ControlSource` and `AdvisorSession` at the second pause, before the reconnect check. When connecting a deployment manually, use `FlightSW --m3 normal --gds HOST:PORT` with its generated `FlightTopologyDictionary.json` and GDS `space-packet-space-data-link` framing. Use the host address reachable from the guest for `HOST`.

## M3 deterministic fault cases

```bash
scripts/m3-check.sh 1
```

Omit the argument for the default full cohort. The cases exercise nominal operation, advisor loss, missing output with heartbeat, invalid advice, insufficient geometry, a held IPC reply and sensor isolation. Open `results.tsv` and the per-case configuration and verdict. Recompute a case with the path to the case directory printed by the harness.

```bash
read -r -p 'M3 case directory: ' case_dir
python3 -B FprimeQnxReference/test/int/check-m3.py "$case_dir"
```

## E6 and M4 inference setup

Install the Linux Armadillo, OpenBLAS, cereal and ensmallen development headers. Put Linux `apk-tools` 3.x on `PATH` using the [QNX package codelab](https://qnx.github.io/codelabs/apk-based-cross-compile/index.html). The host and target use mlpack 4.7.0. The following commands prepare new dependency directories outside the repository.

```bash
sudo apt install libarmadillo-dev libopenblas-dev libcereal-dev libensmallen-dev
git clone https://github.com/mlpack/mlpack.git "$HOME/mlpack-4.7.0"
git -C "$HOME/mlpack-4.7.0" checkout --detach d72d9191750cea213c5efadf959d264a7a622420
export E6_HOST_MLPACK_INCLUDE="$HOME/mlpack-4.7.0/src"

SYS="$(mktemp -d "$HOME/fprime-qnx-evidence/sysroot.XXXXXXXX")"
scripts/e6-prepare-sysroot.sh "$SYS"
scripts/e6-check.sh "$SYS"

python3 -m venv "$HOME/.venvs/fprime-qnx-m4"
"$HOME/.venvs/fprime-qnx-m4/bin/python" -m pip install \
    -r FprimeQnxReference/test/m4/requirements.txt
export M4_PYTHON="$HOME/.venvs/fprime-qnx-m4/bin/python"
```

The sysroot links to the installed SDK and adds a signed QNX APK overlay. To reuse a compatible sysroot from an earlier run, point `SYS` there and skip preparation. E6 checks that the target loads its libraries and that the fixed fixture produces matching labels and scores within its configured tolerance. [Inference results](results.md#trained-advisor-and-offline-replay)

## M4 trained advisor and dataset

```bash
scripts/m4-check.sh "$SYS" adcs-pilot
scripts/m4-check.sh "$SYS" adcs
scripts/m4-check.sh "$SYS" opssat
```

The ADCS pilot uses validation seeds. The full ADCS workload uses held-out seeds and checks the FDIR control, the learned advisor, and advisor recovery. Inspect the output per scenario and match the first accepted post-restart result to offline replay. The OPS-SAT exercise uses a separate model and the published test split. For an offline run, pass a third argument to `opssat` pointing to a directory with `record.json` and the pinned Zenodo files consumed by the script. [Dataset](https://doi.org/10.5281/zenodo.15108715)

## M4 slow sensor drift comparison

The host mode freezes the cutoffs and checks the native FFN replay. The target mode repeats those checks before starting a fresh QNX guest.

```bash
scripts/m4-check.sh "$SYS" adcs-drift-host
scripts/m4-check.sh "$SYS" adcs-drift
```

The fixture adds a ramp to channel 0 with a slope fixed by each seed, starting at the same injection cycle as the fixed-bias case. The FFN and the conventional leave-one-out residual both use that channel hypothesis and causal sensor snapshots. Each cutoff is fixed above the maximum score on the healthy calibration seeds, with zero observed false alerts. Fit seeds are 1101–1116, healthy calibration seeds are 2101–2116 and held-out seeds are 3101–3108. The runner alternates the FDIR-only and learned-advisor order for the held-out healthy and drift cases.

A warning can precede the independent confirmation needed for an exclusion proposal. Both arms use the existing RecoveryGate for action, geometry and consistency checks. While FlightSW's own residual warns on a channel that is not yet excluded, FlightSW withholds the fused estimate. An advisor result cannot trigger this. Offline replay also compares warning snapshots on identical input.

Recompute the per-seed report with the script below. It records the first valid warning and its source snapshot, the acting gate, channel isolation, simulated sun-vector error, stable recovery and the original run verdict. [D62](../zh/決策與變更紀錄.md#d62--calibrate-and-pair-the-slow-drift-detectors-2026-11-24) and [D75](../zh/決策與變更紀錄.md#d75--integrate-e7-guard-the-drift-estimate-and-pre-register-the-acceptance-round-2026-11-25) give the limits of the comparison.

```bash
"$M4_PYTHON" FprimeQnxReference/test/m4/assess-drift.py --pairs RUN_DIR
```

## M4 paired repair-policy check

Start with one pair to verify the build, guest, trained advisor warm-up and log transfer. Then run the ten-pair acceptance cohort from the same checkout.

```bash
scripts/m4-check.sh "$SYS" adcs-pair 1
scripts/m4-check.sh "$SYS" adcs-pair 10
```

Each invocation uses one guest and one model for its interleaved cohort. The harness verifies the rendered SLM repair setting while keeping the seed, workload and binaries fixed within each pair. Record the source and Gitlinks, SDK and guest versions, image and binary checksums and the input and model checksums. Check `pairs.tsv`, `results.tsv`, each case's `target-status.txt`, `timing.txt` and `adcs.json`. Keep the first attempt and each retry in its own printed evidence directory with the original full verdict.

For missing releases, `M4_KERNEL_TRACE=on-miss` retains a case's available QNX and host ring evidence. In a separate terminal, run `sudo scripts/m4-tracefs.sh "$USER"` and export the printed `M4_HOST_TRACEFS` in the test shell before enabling `M4_KERNEL_TRACE`. Keep the trace helper running until the cohort finishes. The timing checker uses the same per-case contract in both modes.

The recorded formal cohort used the QEMU/KVM CPU profile `host,tsc-deadline=off`. To use that profile with the runner on the documented Ubuntu host, configure the dedicated trace instance above, then use this launcher.

```bash
mkdir -p "$TMPDIR/qemu-bin"
cat > "$TMPDIR/qemu-bin/qemu-system-x86_64" <<'QEMU'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for ((index=0; index + 1 < ${#args[@]}; ++index)); do
    if [[ "${args[index]}" == --cpu || "${args[index]}" == -cpu ]] && [[ "${args[index+1]}" == host ]]; then
        args[index+1]=host,tsc-deadline=off
    fi
done
exec /usr/bin/qemu-system-x86_64 "${args[@]}"
QEMU
chmod 700 "$TMPDIR/qemu-bin/qemu-system-x86_64"
PATH="$TMPDIR/qemu-bin:$PATH" M4_KERNEL_TRACE=on-miss scripts/m4-check.sh "$SYS" adcs-pair 10
```

Verify the effective profile in `qemu-argv.txt`. The recorded cohort used a local copy of the boot-verified stopped short-run image. The command above provisions a fresh image and records its checksum.

Generate the application behavior summary from the recorded pair directory.

```bash
read -r -p 'M4 paired run directory: ' m4_run_dir
"$M4_PYTHON" -B FprimeQnxReference/test/m4/fault-report.py --public "$m4_run_dir"
```

To recompute an individual case, use `check-m3.py` on that case directory and run `assess-adcs.py` with the run's offline `replay` directory and the case directory. Use the summary for the restart behavior under the [reviewed publication scope](limitations.md). Keep the detailed report, both arm comparisons, original per-case timing verdicts and trace captures on the test host. Apply the same rule to browser and terminal recordings that contain those outputs. [Paired behavior evidence](evidence-index.md#trained-advisor-recovery)

## M4 advisor-disabled baseline (Q0)

Q0 estimates what running the advisor costs the flight side. Each block runs Q0 and Q1 on the same seed in one guest, alternating their order. Q0 uses the Q1 crash workload with the FDIR-only entry, so SLM starts FlightSW alone with the same arguments and the advisor never runs. Use the same CPU profile launcher as for the paired check.

```bash
PATH="$TMPDIR/qemu-bin:$PATH" scripts/m4-check.sh "$SYS" adcs-q0 10
```

`blocks.tsv` records each block's order and checks that the two rendered SLM files differ only by the advisor's model argument. Each Q0 case passes the FDIR-only recovery checks under the same release and deadline as Q1. Compare the per-case `timing.txt` within each block. [D79](../zh/決策與變更紀錄.md#d79--pre-register-the-q0-advisor-cost-round-2026-11-26) fixes the metrics and verdict labels. Keep the timing comparison on the test host, as for the paired check. Set `M4_KERNEL_TRACE=1` to keep the guest ring of every case; [D80](../zh/決策與變更紀錄.md#d80--pre-register-the-attribution-of-the-q1-lifecycle-transients-2026-11-26) used it to examine the timing transients near advisor start-up and restart.

## SDK-free host checks

```bash
scripts/check-public-docs.sh
python3 -B scripts/check-markdown-links.py
python3 -B -m unittest discover -s FprimeQnxReference/test/m4 -p test_fault_report.py
```

The [host workflow](../../.github/workflows/host-checks.yml) adds ShellCheck, Python compilation and the RecoveryGate C++ test. Use the target steps above for QNX cross-build, boot and runtime evidence.
