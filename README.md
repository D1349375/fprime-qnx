# F Prime on QNX

This project ports NASA/JPL F Prime to QNX 8.0 for the QNX Global Hackathon **Open-Source Contribution & Ports** category. The port provides a reusable platform library. Upstream Ref demonstrates adoption, and a separate simulated ADCS reference deployment exercises two-process communication, timing, and advisor recovery. A deterministic advisor exercises the recovery gate and fault handling. See the implementation log for validation status.

## Bring-up status

The x86-64 toolchain, QNX platform library, and pulse-driven `QnxTimer` run the upstream F Prime v4.4.2 `Ref` deployment on QNX 8.0 under QEMU/KVM. The ground data system (GDS) sends `CMD_NO_OP` and receives its two events and rate group 1 telemetry. The M2 reference also runs two F Prime deployments using simulated sun sensors and deterministic advice. The [implementation log](docs/實作迭代紀錄.md) records platform and reference-deployment evidence.

Start with the [ASUS VivoBook X409JP setup guide](docs/setup-asus-vivobook.md). It covers Ubuntu on WSL2, KVM, QNX SDP, headless QEMU, and the F Prime tooling.

## Reproduce M1

In Ubuntu, activate the F Prime virtual environment and source the local QNX SDP 8.0 environment. Set up the libvirt `default` network and QEMU bridge as described in the ASUS guide. Clone a revision that includes the validation scripts, then run:

```bash
scripts/clean-rebuild.sh
```

The script clones the current checkout's committed revision into a new directory, initializes the pinned submodules, builds `Ref`, creates and boots an x86-64 QNX image, and runs the GDS check. It prints the directory containing the source revisions, build logs, and target evidence. [QNX mkqnximage reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html)

For the upstream OSAL suites, initialize the submodules with `git submodule update --init --recursive` and run `scripts/osal-check.sh`. It applies the [test portability patch](adoption/osal-test-portability.patch) to a staged copy of the pinned framework and provisions a new x86-64 QNX guest. Evidence and the default build cache go under `TMPDIR` or `/tmp`. Set `QNX_IMAGE_DIR` and `QNX_SSH_KEY` to use a provisioned image with sufficient space. `OSAL_BUILD_DIR` accepts a cache produced by the same staged test sources.

## Reproduce M2

Use the same QNX and QEMU environment as M1, with the pinned submodules initialized and Python 3.9 or newer. Run these commands from the repository root for a fresh checkout.

```bash
(cd FprimeQnxReference && fprime-util generate qnx-x86_64 && fprime-util build qnx-x86_64 --jobs 2)
scripts/m2-check.sh udp
scripts/m2-check.sh qnx
scripts/m2-check.sh slm
```

The `udp` and `qnx` checks delay the advisor to fill the bounded snapshot queue, then stop it during the 200-cycle flight run. The `slm` check uses the QNX IPC transport and kills the supervised advisor once. It checks for a new advisor process and session, expiry of old advice, and an uninterrupted flight trace. The harness stages the SLM utilities and libraries from the installed QNX SDK on the test guest. It renders a test copy of the [SLM template](FprimeQnxReference/qnx/m2-slm.xml.in) with process criticality disabled so the test can stop flight cleanly. [QNX SLM reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/s/slm.html)

Each command prints the evidence directory. `flight.csv` contains cycle ID, scheduled release, actual start, and the time at which FlightSW updates its internal sun estimate. All three timestamps use the guest's monotonic clock. `summary.txt` reports time from release to that estimate update and observed misses against the 20 ms period. The iteration log records the initial QEMU/KVM validation and the v0.3 clean regression. [M2 results](docs/實作迭代紀錄.md#i-12--v03-整合基準-qnx-客體重跑)

## Reproduce M3 and E6

Use Ubuntu 24.04 with the F Prime virtual environment and QNX SDP 8.0.6. Initialize the pinned submodules and reuse
the M1 libvirt network setup. Run one pilot round before the full target validation.

```bash
git submodule update --init --recursive
scripts/m3-check.sh 1
scripts/m3-check.sh
```

M3 uses a deterministic advisor and simulated coarse sun sensors. Each run checks a no-fault baseline, SLM restart
(Q1), SLM repair disabled (Q2), missing output with heartbeat, invalid advice, insufficient sensor geometry,
a held native IPC reply with its unblock pulse, and successful sensor isolation. Q1 and Q2 use the same guest and
binaries. The harness prints its evidence directory and writes the per-round verdicts to `results.tsv`. Use `python3 FprimeQnxReference/test/int/check-m3.py RUN_DIR`
to recompute a single round from its config, flight and IPC CSVs, and advisor log. Q1 and Q2 additionally capture
QNX process-manager death notifications in `death.csv`. The observer timestamps pulse reception independently of the
flight and IPC workers. That timestamp bounds the exit time from above. See
[M3 decisions](docs/決策與變更紀錄.md#d21--m3-飛行提交與故障驗收) for the pilot contract.

E6 builds the same C++17 mlpack 4.7 FFN on Linux and QNX x86-64. On Ubuntu 24.04, install the Armadillo,
OpenBLAS, cereal and ensmallen development packages. Use the upstream mlpack 4.7.0 headers. Set
`E6_HOST_MLPACK_INCLUDE` if those headers are outside the Linux compiler's default search path.
[mlpack 4.7.0 source](https://github.com/mlpack/mlpack/tree/d72d9191750cea213c5efadf959d264a7a622420)

Source the installed QNX SDP 8.0.6, put Linux `apk-tools` 3.x on `PATH`, and use the M1 libvirt setup.
The preparation script builds an isolated sysroot from signed QNX 8.0.3 APKs and links to the installed
x86-64 SDK headers and libraries. Pass a fresh directory outside the checkout.
[QNX APK sysroot codelab](https://qnx.github.io/codelabs/apk-based-cross-compile/index.html)

```bash
scripts/e6-prepare-sysroot.sh "$HOME/e6-qnx-x86_64"
E6_HOST_MLPACK_INCLUDE="$HOME/mlpack-4.7.0/src" scripts/e6-check.sh "$HOME/e6-qnx-x86_64"
```

The runner also accepts an existing compatible x86-64 APK sysroot. It records source and package versions,
loader output, weights hash, and score and label comparisons. On QNX x86-64, the fixed fixture matched
the Linux results and the independent numerical reference. [E6 verification](docs/實作迭代紀錄.md#i-22--e6-固定權重推論驗收2026-11-20)

## Reproduce the ADCS GDS check

Build the QNX reference deployment as in M2, activate the F Prime environment, and source the QNX SDP.
Then run these commands from the repository root.

```bash
scripts/gds-check.sh
scripts/ground-timing-check.sh
```

The GDS check uses the M3 SLM template and the deterministic advisor. It sends `CMD_NO_OP`,
stops the advisor, and checks FDIR engagement, acceptance of a new advisor session, and the
control-source transitions. The test copy of the SLM configuration gives ground telemetry a sampling window during FDIR.
It then restarts GDS and checks that the same FlightSW process
continues and reconnects. Use `scripts/gds-check.sh --ui` and open the local GDS on port 5000
to inspect Events and the `ControlSource` channel when the script pauses.

`FlightSW --m3 normal --gds HOST:PORT` enables the command, event, and telemetry services.
Use the generated `FlightTopologyDictionary.json` and the `space-packet-space-data-link` GDS
framing configuration. `GDS_EVIDENCE_ROOT` selects an output directory outside the checkout.
The timing script alternates GDS off and on with the same replay seed and writes its per-run
evidence there. [GDS implementation and verification](docs/實作迭代紀錄.md#i-58--connect-flightsw-to-gds-2026-11-23)

## Reproduce M4

Use the M3 QNX x86-64 environment and the E6 APK sysroot. On Linux, use the mlpack 4.7.0
headers and the E6 Armadillo and OpenBLAS development dependencies. Activate the F Prime
environment and source the QNX SDP environment before running these commands.

```bash
python3 -m venv "$HOME/m4-training"
"$HOME/m4-training/bin/pip" install -r FprimeQnxReference/test/m4/requirements.txt
export M4_PYTHON="$HOME/m4-training/bin/python"
export E6_HOST_MLPACK_INCLUDE="$HOME/mlpack-4.7.0/src"

scripts/m4-check.sh "$HOME/e6-qnx-x86_64" adcs-pilot
scripts/m4-check.sh "$HOME/e6-qnx-x86_64" adcs
scripts/m4-check.sh "$HOME/e6-qnx-x86_64" opssat
```

Each invocation creates its own QNX guest and prints an evidence directory under `TMPDIR`
or `/tmp`. Set `M4_QNX_BUILD_CACHE` to an external directory to reuse the cross-build cache.
The `opssat` command downloads the pinned Zenodo files, or accepts a directory containing the
same files and the Zenodo `record.json` as its third argument. The two experiments train
separate one-hidden-layer FFNs and use the same C++17 inference code on Linux and QNX.
[OPSSAT-AD v2 dataset](https://doi.org/10.5281/zenodo.15108715)

For ADCS, the runner compares the FDIR control and learned advisor on matching seed,
bias injection, and Gate conditions. It checks that each accepted live result matches
the offline replay, then verifies FDIR fallback and SLM restart with the trained advisor.
The pilot uses validation seeds. The formal run uses held-out seeds and performs ten crash
trials. The default M3 build continues to use the deterministic advisor. The optional FFN
build takes `-DFPRIME_QNX_M4_SYSROOT=/path/to/e6-sysroot` and enables `MlAdvisor --model PATH`.

For OPSSAT-AD, only the author's training set supplies fitting and validation data. The
author's test set is used after preprocessing, weights, and the threshold are frozen.
Both commands write `replay/comparison.csv` with one row per expected case. `replay/summary.txt`
reports inference failures and score and label differences using the full held-out
denominator, as well as segment classification metrics and inference latency.
ADCS records target traces in guest shared memory during each flight. It exports them with
`results.tsv` and the per-run timing and recovery reports.

### Run the ADCS fault benchmark

In the M4 environment above, from an initialized checkout, run the paired experiment.

~~~bash
scripts/m4-check.sh "$HOME/e6-qnx-x86_64" adcs-pair
~~~

The default is ten interleaved pairs. Set the optional third argument for a shorter run.
Each pair runs the same held-out seed and frozen FFN in one guest with fresh FlightSW and
advisor processes. The SLM XML check verifies the advisor's repair policy in both arms.
The fixed crash trigger is the first eligible snapshot from cycle 55 onward. The report
shows the actual snapshot and injection offset for each arm. A per-run marker in QNX
shared memory records that the advisor has claimed the injection. SLM's replacement
uses the same marker, and the harness clears it before each new scenario.
The timing checker records whether flight accepted its first advisor result by cycle 40.

Add `M4_KERNEL_TRACE=1` before the command to capture the QNX memory ring in both arms.
The ring is exported after each scenario. Use the SDP's `traceprinter` with
`-n -p '%c|%C|%Z|%z|' -f trace.kev` to decode it. Each trace includes two guest clock anchors.

To retain both scheduler traces when a deadline may have been missed, run
`sudo scripts/m4-tracefs.sh "$(id -un)"` in a second Linux terminal and keep it open
for the run. The helper prints a dedicated tracefs path. Pass that path to any ADCS
mode, for example

~~~bash
M4_HOST_TRACEFS=/run/fprime-adcs-trace.REPLACE_ME M4_KERNEL_TRACE=on-miss \
    scripts/m4-check.sh "$HOME/e6-qnx-x86_64" adcs-pair 2
~~~

The watcher reads the guest's existing, line-buffered flight records over a persistent
SSH connection. A cycle gap, failed or late submission, loss of flight progress or
a stalled guest reply retains the host ring. A responsive guest exports its QNX ring
after a short recovery window. If a stalled observation resumes with the affected
cycles on time, the watcher clears that provisional trigger and continues watching.
`watch.json` gives the trigger, any observed deadline failure and capture status.
The clock brackets in `clock-anchors.tsv` bound alignment.
The watcher stores host scheduling events by QEMU thread name and records the test
guest's local TIDs and CPU masks. Use one QEMU guest at a time for clear attribution
when the kernel trace uses a different PID namespace. The original checker still
computes the 20 ms verdict from the complete flight records. Healthy scenarios keep
the watcher status and skip transferring the rings. Stop the tracefs helper when the
test ends.

Open `fault-report.md` in the printed evidence directory. It links to each round's
configuration, original checker output, raw guest timeline, available trace, SDK
packages and source and model revisions. The command returns a nonzero status if
a verdict fails, a pair's XML differs outside the repair field, or a requested trace
is incomplete. Keep evidence local according to §9.4 of the [project plan](docs/專案規劃書.md).

To generate an application-behavior summary from a recorded paired run, use

~~~bash
python3 -B FprimeQnxReference/test/m4/fault-report.py --public RUN_DIR
~~~

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

Upstream framework and planned release are maintained by [NASA/JPL F Prime](https://github.com/nasa/fprime). The [Devpost official rules](https://qnx.devpost.com/rules) govern the submission.
