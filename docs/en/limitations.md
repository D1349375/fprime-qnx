
# Limitations

| Area | Current coverage |
| --- | --- |
| QNX runtime | QNX SDP 8.0.6 with `qcc` GCC 12.2.0, QNX 8.0.0 x86-64 on QEMU/KVM under Ubuntu 24.04.5 and WSL2. |
| AArch64 and hardware | The [`qnx-aarch64le` toolchain file](../../FprimeQnx/cmake/toolchain/qnx-aarch64le.cmake) is present. AArch64 build and execution and physical QNX hardware are unverified. |
| Flight scheduling | Repeated WSL2/QEMU tests observed occasional missing cycles. The local evidence placed the immediate symptom on the virtual timer delivery path. The underlying host cause and a verified fix remain open. The checker evaluates every planned release against the configured deadline for its own run. The paired summary reports application recovery behavior. Each original timing verdict remains in the local evidence and applies to its own case. The formal E5 cohort used one QEMU CPU profile with TSC deadline disabled. Native Linux/KVM and physical timing coverage remain open. |
| OSAL | `Os::Cpu` and `Os::Memory` select upstream stubs. The suite table separates stub coverage, unsupported Linux-only task cases, the target file test skipped without `/dev/full`, and the ThreadSanitizer suite outside the QNX run. [OSAL results](results.md#osal-v1) |
| Deployment components | The port excludes the stock POSIX UART driver from QNX builds because the SDK headers lack the two symbols it uses. The Ref example omits the Rust-backed `WasmSequencer` and keeps `cmdSeq`. [Upstream status](upstream.md) |
| ADCS and ML | Dynamics and coarse sun sensors are simulated. The learned advisor covers one fixed positive bias on the +X sensor. The detector and independent FDIR first alerted on the same cycle in the recorded exercise. The example exercises subsequent sensor isolation and recovery. OPS-SAT telemetry is a separate offline exercise. [Application results](results.md#trained-advisor-and-offline-replay) |
| Ground and fault monitoring | GDS services run in FlightSW on separate threads from the periodic estimation work. With native IPC and GDS enabled, FlightSW reports the watched advisor's `ProcessDied` event along with FDIR engagement, session changes and control source. Non-root subscription policy and overlapping advisor handovers remain unverified. |
| Authority and safety | FlightSW owns the ADCS decision. The Gate authorizes a limited sensor exclusion and the estimator can return a degraded state. Spacecraft-wide safe mode remains outside the advisor interface. This is a simulated engineering reference with no safety certification. |
| Hosted CI | The Ubuntu workflow checks publication scope, shell and Python sources, RecoveryGate logic, report fixtures and internal links. QNX build, boot and runtime validation use the local SDK and guest. [Workflow](../../.github/workflows/host-checks.yml) |

See the [evidence index](evidence-index.md) for the source revision and reproduction check behind each claim.
