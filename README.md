# F Prime on QNX

F Prime on QNX ports NASA/JPL's F Prime flight software framework to QNX 8.0. The port builds and runs upstream `Ref` on an x86-64 QNX guest, where the F Prime ground data system (GDS) sends a command and receives events and telemetry. A separate simulated attitude determination and control system (ADCS) shows how FlightSW continues submitting estimates when its machine-learning advisor exits.

Start with the [Ref/GDS check](#reproduce-m1), then run the [trained-advisor fault scenario](#reproduce-m4). The [QNX evidence index](docs/qnx-evidence.md) connects each claim to its source, reproduction command, and pass criteria.

## Validated environment

| Item | Version or configuration |
| --- | --- |
| Host | Ubuntu 24.04.5 under WSL2 with an active libvirt `default` network and QEMU bridge |
| SDK and compiler | QNX SDP 8.0.6, `qcc` GCC 12.2.0, `gcc_ntox86_64` |
| Target | QNX 8.0.0 x86-64 on QEMU 8.2.2/KVM with two vCPUs and 1536 MiB of memory |
| Framework | F Prime v4.4.2, pinned as a Git submodule |

Install your own QNX SDK and set up the F Prime Python environment, KVM, and libvirt before running the checks. The commands assume the SDK and virtual environment paths used in the [host setup guide](docs/setup-asus-vivobook.md). Adjust those paths as needed.

## Adopt the platform library

Register `FprimeQnx/` through `library_locations` in the deployment's `settings.ini` and select the `qnx-x86_64` toolchain. The port supplies a QNX platform configuration, POSIX OSAL selections, and `Svc.QnxTimer`, which uses QNX pulses to drive F Prime rate groups. The Ref adoption patch preserves the timer connections while switching the timer type and adapting the topology to the target. [Project settings](adoption/settings.ini) · [Ref patch](adoption/ref-qnx.patch) · [Platform notes](docs/upstream-notes.md)

## Reproduce M1

Clone the exact revision used for target validation and run the clean build from the repository root. The runner initializes submodules in a fresh copy, cross-builds `Ref`, and boots a new QNX image.

```bash
candidate=eef1b35a036cd7c2de7db217b548eb80867e98fd
git clone https://github.com/D1349375/fprime-qnx.git fprime-qnx-review
cd fprime-qnx-review
git checkout --detach "$candidate"
git submodule update --init --recursive

source "$HOME/qnx800/qnxsdp-env.sh"
source "$HOME/.venvs/fprime-qnx/bin/activate"
evidence=$(mktemp -d "$HOME/fprime-qnx-evidence.XXXXXXXX")
FPRIME_QNX_REF="$candidate" scripts/clean-rebuild.sh "$evidence/ref"
```

A successful run exits `0` and identifies a QNX x86-64 guest. GDS sends `CMD_NO_OP` and receives `NoOpReceived`, `OpCodeCompleted`, and a sample from `Ref.rateGroup1Comp.RgMaxTime`. The run directory contains source, build, image and GDS logs. Use a free `GDS_PORT` if the default TCP port 50000 is occupied. `RgMaxTime` publishes on change, so the GDS probe's `CHECK_SECONDS` controls how long to wait for telemetry. [Ref evidence](docs/qnx-evidence.md#ref-and-gds)

## Reproduce M4

The simulated ADCS uses separate `FlightSW` and `MlAdvisor` processes. A bounded handoff lets an IPC worker exchange snapshots and advice through native QNX messages. FlightSW owns the recovery decision. Its recovery gate checks advice against the current session and snapshot, and independent fault detection, isolation, and recovery (FDIR) logic takes over when valid advice stops arriving. QNX System Launch and Monitor (SLM) starts a replacement advisor after an abnormal exit.

Continue in the Ref checkout and shell. Install the Ubuntu development packages `libarmadillo-dev`, `libopenblas-pthread-dev`, `libcereal-dev`, and `libensmallen-dev`. Check that `pkg-config --modversion armadillo openblas` resolves both libraries. Put Linux `apk-tools` 3.x on `PATH` to build the E6 x86-64 sysroot from signed QNX APKs and the installed SDK. An existing compatible E6 sysroot can also be used. [QNX APK sysroot guide](https://qnx.github.io/codelabs/apk-based-cross-compile/index.html)

```bash
sysroot="$evidence/e6-sysroot"
scripts/e6-prepare-sysroot.sh "$sysroot"

git clone --filter=blob:none https://github.com/mlpack/mlpack.git "$evidence/mlpack"
git -C "$evidence/mlpack" checkout --detach d72d9191750cea213c5efadf959d264a7a622420

python3 -m venv "$evidence/training-env"
"$evidence/training-env/bin/pip" install -r FprimeQnxReference/test/m4/requirements.txt
export M4_PYTHON="$evidence/training-env/bin/python"
export E6_HOST_MLPACK_INCLUDE="$evidence/mlpack/src"

TMPDIR="$evidence" scripts/m4-check.sh "$sysroot" adcs-pilot
```

The pilot passes when the runner exits `0` with every row in `results.tsv` marked `PASS`. In `2001-q1-01`, look for continued flight submissions, FDIR takeover, an SLM replacement, rejection of the old session with `R2_SESSION`, and acceptance of the replacement advisor's first replay-checked inference. [Q1 evidence and recheck commands](docs/qnx-evidence.md#trained-advisor-fault-and-recovery)

The following commands reproduce the formal held-out ADCS tests and the separate OPS-SAT replay. The ADCS run compares paired FDIR and learned-advisor scenes and includes ten advisor crash trials. Each invocation prints its evidence directory. Set `M4_QNX_BUILD_CACHE` to a compatible external directory to reuse cross-build artifacts.

```bash
TMPDIR="$evidence" scripts/m4-check.sh "$sysroot" adcs
TMPDIR="$evidence" scripts/m4-check.sh "$sysroot" opssat
```

The OPS-SAT runner downloads the pinned dataset and metadata from Zenodo. It also accepts the same files with `record.json` as its third argument. The optional trained-advisor build uses `-DFPRIME_QNX_M4_SYSROOT=/path/to/e6-sysroot` and starts `MlAdvisor` with `--model PATH`. [M4 runner](scripts/m4-check.sh)

## Model and data provenance

The project trains two one-hidden-layer feed-forward networks (FFNs) with scikit-learn `MLPClassifier` on the host, then evaluates the exported weights with the same mlpack 4.7.0 C++ inference code on Linux and QNX. [Training code](FprimeQnxReference/test/m4/train.py) · [Inference code](FprimeQnxReference/MlDeployment/Ffn.cpp)

- **ADCS** uses a 5 → 8 → 1 network trained on simulated sun-sensor data. The inputs are four illumination readings and a projection residual. The formal comparison pairs the FDIR control and learned advisor on the same held-out seeds and fixed sensor fault.
- **OPS-SAT** uses an 18 → 16 → 1 network trained on the published telemetry features from Bogdan Ruszczak and the OPSSAT-AD team. The author's training split supplies fitting and validation data. Preprocessing, weights, and the decision threshold are frozen before evaluating the author's test split. Dataset release v2 is recorded as CC BY 4.0 on Zenodo and includes a KP Labs MIT license notice in the release files. [OPSSAT-AD v2](https://doi.org/10.5281/zenodo.15108715) · [Benchmark paper](https://arxiv.org/abs/2407.04730)

## Reproduce M2

With the SDK and F Prime environment active and the pinned submodules initialized, build the reference project and exercise the native IPC, UDP control, and SLM restart paths.

```bash
(cd FprimeQnxReference && fprime-util generate qnx-x86_64 && fprime-util build qnx-x86_64 --jobs 2)
scripts/m2-check.sh udp
scripts/m2-check.sh qnx
scripts/m2-check.sh slm
```

The `udp` and `qnx` cases delay the advisor to fill the bounded snapshot queue, then stop it during the flight run. The `slm` case checks for a new advisor process and session, expiry of old advice, and continuing flight submissions. The harness prints its evidence directory. `flight.csv` records scheduled release, actual start, and estimate submission on the guest's monotonic clock. The test copy of the SLM template disables FlightSW process criticality to support a clean harness shutdown. [M2 SLM template](FprimeQnxReference/qnx/m2-slm.xml.in)

## Reproduce M3 and E6

Run a single deterministic fault round before the full M3 matrix. Q1 and Q2 run on the same guest and binaries, with different SLM repair policies. The matrix covers lost advisor output, rejected advice, degraded sensor geometry, a held native IPC reply, and sensor isolation.

```bash
scripts/m3-check.sh 1
scripts/m3-check.sh
```

With the E6 sysroot and Linux development dependencies configured as described for M4, run the fixed-weight inference check. It builds the same C++ fixture for Linux and QNX and compares both outputs with an independent numerical reference.

```bash
scripts/e6-check.sh "$sysroot"
```

## OSAL coverage and limits

Run the upstream operating system abstraction layer (OSAL) suites with `scripts/osal-check.sh` from a validation checkout with initialized submodules. By default the runner provisions its own guest and writes a per-suite summary and target logs. It also accepts `QNX_IMAGE_DIR` and `QNX_SSH_KEY` for a provisioned guest. Preserve passing, failed and skipped cases. CPU and memory use upstream stubs, and the stock POSIX UART driver is excluded from the QNX build. [OSAL evidence](docs/qnx-evidence.md#coverage-and-repeatability) · [Portability notes](docs/upstream-notes.md)

The target evidence covers x86-64 QEMU/KVM and a simulated fixed sensor bias. M5 repeats on the same host included pilot runs with missing flight records or delayed advisor readiness. AArch64 runtime, physical-board validation, and broader sensor fault coverage remain open. [QNX evidence index](docs/qnx-evidence.md#coverage-and-repeatability)

## Project documents

| Document | Contents |
| --- | --- |
| [Project plan v0.3](docs/專案規劃書.md) | Platform and adoption scope, M2 evidence, and formal fault validation |
| [Decision log](docs/決策與變更紀錄.md) | Design decisions and the ASUS handoff |
| [Implementation log](docs/實作迭代紀錄.md) | Iterations, validation evidence, and agent handoff |
| [W1 environment log](docs/W1環境建置紀錄.md) | Host bring-up, toolchain, and QNX target results |
| [Upstream notes](docs/upstream-notes.md) | F Prime portability findings and upstream candidates |
| [Competition brief](docs/競賽資訊.md) | Rules and submission checklist from the initial research |
| [QNX 8.0 constraints](docs/QNX8.0與開發限制.md) | Host, target, toolchain, and platform constraints |
| [Ports candidates](docs/Ports候選專案.md) | Comparison that led to the F Prime choice |
| [AI design research](docs/AI深化方向.md) | Telemetry data, anomaly detection, and recovery gate research |
| [Previous QNX projects](docs/歷屆得獎作品調研.md) | Dated research on prior winners and published entries |

The port is an [Apache-2.0](LICENSE) entry for the QNX Global Hackathon Open-Source Contribution & Ports category. [NASA/JPL F Prime upstream](https://github.com/nasa/fprime) · [Official rules](https://qnx.devpost.com/rules)
