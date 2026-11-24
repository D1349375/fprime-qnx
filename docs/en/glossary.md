# Glossary

| Term | Meaning in this project |
| --- | --- |
| ADCS | Attitude determination and control system. The reference deployment simulates coarse sun sensors and commits a sun-vector estimate. |
| FlightSW | The F Prime process that produces the estimate, runs FDIR and owns the recovery decision. |
| ML advisor (`MlAdvisor`) | A separate F Prime process that reads telemetry snapshots and returns advice. The fault harness can use either a deterministic advisor or a trained feed-forward neural network (FFN). |
| FDIR fallback | Fault detection, isolation and recovery performed by FlightSW when advice is unavailable or unusable. |
| RecoveryGate | The run-time assurance monitor in FlightSW. It checks proposed recovery actions against deterministic rules before they can affect the estimate. |
| Session | The FlightSW-assigned identity for an advisor handshake. FlightSW correlates advice with the active session and an issued snapshot. |
| Rejoin with a fresh session | FlightSW adopts eligible advice from a replacement session after fallback. A process restart alone supplies a new advisor process. |
| SLM | QNX System Launch and Monitor. The harness uses it to launch the two processes and exercise the configured advisor repair policy. |
| Paired comparison (Q1/Q2) | Two runs sharing guest, binaries, model and seed. Q1 sets `repair=restart` and Q2 sets `repair=none` for the advisor. |
| Release and deadline | A scheduled flight cycle's intended start and its configured commit limit. The checker includes scheduled releases even when a flight record is missing. |
| Denominator | The expected population for a check, such as every scheduled flight cycle or every held-out inference input. |
| OSAL | F Prime's operating system abstraction layer. The QNX port selects the applicable POSIX implementations and CPU and memory stubs. |
| GDS | F Prime's Ground Data System for sending commands and viewing structured events and telemetry. |
| SDP | The locally installed QNX Software Development Platform, including the `qcc` cross-compiler and image tooling. |
