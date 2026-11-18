# F Prime on QNX

This project plans an independent port of NASA/JPL F Prime to QNX 8.0 for the QNX Global Hackathon **Open-Source Contribution & Ports** category. The reference design separates the flight software and a telemetry anomaly detector into two processes. A deterministic gate checks the recovery actions suggested by the detector.

## Bring-up status

The port is at W1 environment bring-up. The next result to record is an x86-64 QNX guest boot and a C smoke test linked with `qcc` on the ASUS development laptop. The F Prime QNX toolchain, platform layer, and Hello World deployment are planned implementation milestones.

Start with the [ASUS VivoBook X409JP setup guide](docs/setup-asus-vivobook.md). It covers Ubuntu on WSL2, KVM, QNX SDP, headless QEMU, and the F Prime tooling.

## Project documents

| Document | Contents |
| --- | --- |
| [Project plan](docs/專案規劃書.md) | Architecture, milestones, QNX evidence, and validation plan |
| [Decision log](docs/決策與變更紀錄.md) | Design decisions and the ASUS handoff |
| [W1 environment log](docs/W1環境建置紀錄.md) | Original host bring-up and a place to record the ASUS results |
| [Competition brief](docs/競賽資訊.md) | Rules and submission checklist from the initial research |
| [QNX 8.0 constraints](docs/QNX8.0與開發限制.md) | Host, target, toolchain, and platform constraints |
| [Ports candidates](docs/Ports候選專案.md) | Comparison that led to the F Prime choice |
| [AI design research](docs/AI深化方向.md) | Telemetry data, anomaly detection, and recovery gate research |
| [Previous QNX projects](docs/歷屆得獎作品調研.md) | Dated research on prior winners and published entries |

Upstream framework and planned release are maintained by [NASA/JPL F Prime](https://github.com/nasa/fprime). The [Devpost official rules](https://qnx.devpost.com/rules) govern the submission.
