# F Prime on QNX

This project ports NASA/JPL F Prime to QNX 8.0 for the QNX Global Hackathon **Open-Source Contribution & Ports** category. The port provides a reusable platform library. Upstream Ref demonstrates adoption, and a separate simulated ADCS reference deployment exercises two-process communication, timing, and advisor recovery. The deterministic recovery gate and ML evaluation are planned milestones.

## Bring-up status

The x86-64 toolchain, QNX platform library, and pulse-driven `QnxTimer` run the upstream F Prime v4.4.2 `Ref` deployment on QNX 8.0 under QEMU/KVM. The ground data system (GDS) sends `CMD_NO_OP` and receives its two events and rate group 1 telemetry. The M2 reference also runs two F Prime deployments using simulated sun sensors and deterministic advice. The [implementation log](docs/實作迭代紀錄.md) records platform and reference-deployment evidence.

Start with the [ASUS VivoBook X409JP setup guide](docs/setup-asus-vivobook.md). It covers Ubuntu on WSL2, KVM, QNX SDP, headless QEMU, and the F Prime tooling.

## Reproduce M1

In Ubuntu, activate the F Prime virtual environment and source the local QNX SDP 8.0 environment. Set up the libvirt `default` network and QEMU bridge as described in the ASUS guide. Clone a revision that includes the validation scripts, then run:

```bash
scripts/clean-rebuild.sh
```

The script clones the current checkout's committed revision into a new directory, initializes the pinned submodules, builds `Ref`, creates and boots an x86-64 QNX image, and runs the GDS check. It prints the directory containing the source revisions, build logs, and target evidence. [QNX mkqnximage reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/m/mkqnximage.html)

For the upstream OSAL suites, initialize the submodules with `git submodule update --init --recursive` and run `scripts/osal-check.sh` from the same revision. Each run defaults to a new x86-64 QNX guest with extra space for death-test core files. Set `QNX_IMAGE_DIR` and `QNX_SSH_KEY` to use your own provisioned image with sufficient space. The OSAL log directory contains the suite results and target output.

## Reproduce M2

Use the same QNX and QEMU environment as M1, with the pinned submodules initialized and Python 3.9 or newer. Run these commands from the repository root.

```bash
(cd FprimeQnxReference && fprime-util build qnx-x86_64 --jobs 3)
scripts/m2-check.sh udp
scripts/m2-check.sh qnx
scripts/m2-check.sh slm
```

The `udp` and `qnx` checks delay the advisor to fill the bounded snapshot queue, then stop it during the 200-cycle flight run. The `slm` check uses the QNX IPC transport and kills the supervised advisor once. It checks for a new advisor process and session, expiry of old advice, and an uninterrupted flight trace. The harness stages the SLM utilities and libraries from the installed QNX SDK on the test guest. It renders a test copy of the [SLM template](FprimeQnxReference/qnx/m2-slm.xml.in) with process criticality disabled so the test can stop flight cleanly. [QNX SLM reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.utilities/topic/s/slm.html)

Each command prints the evidence directory. `flight.csv` contains cycle ID, scheduled release, actual start, and the time at which FlightSW updates its internal sun estimate. All three timestamps use the guest's monotonic clock. `summary.txt` reports time from release to that estimate update and observed misses against the 20 ms period. UDP and native IPC each passed 200 cycles, and the SLM restart run passed 150 cycles in QEMU/KVM. The iteration log records the tested revision, results, and evidence. ML inference, fault-injection comparisons, and qualification under load are later milestones. [M2 results](docs/實作迭代紀錄.md#i-10--驗收-udp原生-ipc-與-slm)

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
