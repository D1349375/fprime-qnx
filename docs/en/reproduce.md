
# Reproduce

Follow [Host setup](host-setup.md) for Ubuntu, KVM, the libvirt guest network and the local QNX SDP. Run target checks from an x86-64 Ubuntu shell. The exact source tested for each result appears in the [evidence index](evidence-index.md).

## Checkout and environment

This revision contains the port, the ADCS ground integration, the paired report and the host checks. Use it for the commands below.

```bash
git clone --no-checkout https://github.com/D1349375/fprime-qnx.git
cd fprime-qnx
git checkout --detach 7d19287877e6a426d8481e90af07055667444ebd
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

The script starts GDS and boots a QNX guest with FlightSW and the deterministic advisor. It sends `CMD_NO_OP`, stops the managed advisor and validates `FdirEngaged` and `AdvisorAccepted` in receive order, with `ControlSource` changing from ML to FDIR and back to ML. It checks a GDS restart and reconnect with the same FlightSW process, then shuts FlightSW down. [Ground event verifier](../../FprimeQnxReference/test/int/check-gds.py)

To inspect the web UI, run `scripts/gds-check.sh --ui` and open [localhost:5000](http://localhost:5000/) while the script pauses. Check Events for the command and recovery events and Channels for `ControlSource` and `AdvisorSession`. When connecting a deployment manually, use `FlightSW --m3 normal --gds HOST:PORT` with its generated `FlightTopologyDictionary.json` and GDS `space-packet-space-data-link` framing. Use the host address reachable from the guest for `HOST`.

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

## M4 paired repair-policy check

```bash
scripts/m4-check.sh "$SYS" adcs-pair
```

The default is ten interleaved pairs. Pass an optional pair count to shorten a local check. The harness uses the same workload, model, image and binaries per pair and checks the rendered SLM XML for the repair-only change. Examine `pairs.tsv` and `results.tsv` in the printed run directory and keep the full verdict for each run. A failing checker keeps its evidence directory.

Generate the application behavior summary from the recorded pair directory.

```bash
read -r -p 'M4 paired run directory: ' m4_run_dir
"$M4_PYTHON" -B FprimeQnxReference/test/m4/fault-report.py --public "$m4_run_dir"
```

To recompute an individual case, use `check-m3.py` on that case directory and run `assess-adcs.py` with the run's offline `replay` directory and the case directory. Keep the detailed report, per-cycle records and any trace captures on the test host. Apply the same rule to browser and terminal recordings that contain those outputs. [Paired behavior evidence](evidence-index.md#trained-advisor-recovery)

## SDK-free host checks

```bash
scripts/check-public-docs.sh
python3 -B scripts/check-markdown-links.py
python3 -B -m unittest discover -s FprimeQnxReference/test/m4 -p test_fault_report.py
```

The [host workflow](../../.github/workflows/host-checks.yml) adds ShellCheck, Python compilation and the RecoveryGate C++ test. Use the target steps above for QNX cross-build, boot and runtime evidence.
