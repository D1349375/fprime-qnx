
# Results

Target checks used QNX SDP 8.0.6 with `qcc` GCC 12.2.0 on QNX 8.0.0 x86-64 under QEMU/KVM and WSL2. The [evidence index](evidence-index.md) identifies the revision and acceptance check for each result. The [limitations](limitations.md) describe the coverage of the guest and the test harness.

## Ref and ADCS ground system

| Check | Verified application behavior |
| --- | --- |
| Upstream Ref (V2 and V2b) | A fresh cross-build and QNX image booted and ran Ref. GDS sent `CMD_NO_OP` and received `NoOpReceived`, `OpCodeCompleted` and rate group 1 telemetry. [Reproduce Ref](reproduce.md#ref-and-gds-v2-and-v2b) |
| ADCS FlightSW ground integration | The opt-in F Prime GDS round trip returned both command events. GDS observed `FdirEngaged` after advisor loss, then `AdvisorAccepted` with a new session. `ControlSource` reported ML, FDIR and ML in that order. The same FlightSW process reconnected after a GDS restart. [Reproduce ADCS GDS](reproduce.md#adcs-ground-system) |
| Browser service | The browser-mode smoke loaded the GDS web page and passed the automated ground and reconnect checks. Visual review of Events and Channels is pending for the recording. [Ground integration review](https://github.com/D1349375/fprime-qnx/pull/10) |

## OSAL (V1)

The pinned F Prime v4.4.2 OSAL sources ran with the project's [test portability patch](../../adoption/osal-test-portability.patch) on the QNX target. The test executables reported **258 passed, 0 failed, 1 skipped** across 17 suites. Early V1 used the stock test assumptions and exposed portability failures. The suite table reports the later patched run. [Portability change](https://github.com/D1349375/fprime-qnx/pull/5) · [OSAL rerun](reproduce.md#osal-v1)

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `Os_ut_exe` | 3 | 0 | 0 |
| `Os_FilePathUtils_Test` | 24 | 0 | 0 |
| `Os_SandboxedFile_Test` | 11 | 0 | 0 |
| `PosixFileTest` | 37 | 0 | 1 |
| `PosixConsoleTest` | 2 | 0 | 0 |
| `PosixTaskTest` | 14 | 0 | 0 |
| `PosixMutexTest` | 5 | 0 | 0 |
| `PosixFileSystemTest` | 16 | 0 | 0 |
| `PosixDirectoryTest` | 11 | 0 | 0 |
| `PosixConditionTests` | 2 | 0 | 0 |
| `PosixCountingSemaphoreTest` | 12 | 0 | 0 |
| `PosixRawTimeTest` | 14 | 0 | 0 |
| `PriorityMemQueue_UnitTest` | 48 | 0 | 0 |
| `PriorityQueueTest` | 21 | 0 | 0 |
| `LocklessPriorityQueueTest` | 31 | 0 | 0 |
| `StubCpuTest` | 4 | 0 | 0 |
| `StubMemoryTest` | 3 | 0 | 0 |

`PosixFileErrorHandling.WriteNoSpaceSurfacesError` skipped because the guest lacks `/dev/full`. The ThreadSanitizer queue suite is outside the case totals. Native CPU and memory statistics and Linux-only Task priority and nice behavior are outside the target coverage. The CPU and memory suites verify the selected stubs.

## Deterministic ADCS

| Check | Verified application behavior |
| --- | --- |
| M2 transport | FlightSW and MlAdvisor ran as distinct processes with UDP and native QNX IPC. The tests exercised snapshot queue overflow and flight output after the advisor stopped. [M2 rerun](reproduce.md#m2-process-and-transport-checks) |
| M3 faults | Independent FDIR took over when advice was unavailable. The matrix checks rule-based rejection of invalid advice, degraded output with insufficient geometry, recovery by isolating a faulty sensor and the QNX unblock pulse after a held IPC reply. [M3 rerun](reproduce.md#m3-deterministic-fault-cases) |
| Supervised restart | With `repair=restart`, SLM started a replacement advisor. FlightSW carried on, renewed the session and accepted fresh advice. [SLM configuration](../../FprimeQnxReference/qnx/m3-slm.xml.in) |

## Trained advisor and offline replay

- **E6 fixed-weight fixture.** The Linux host and QNX guest ran the same mlpack FFN with fixed weights. Labels matched and scores met the configured tolerance against the independent reference. [Inference rerun](reproduce.md#e6-and-m4-inference-setup)
- **M4 trained ADCS advisor.** The frozen FFN supplies advice during a simulated +X sun-sensor bias. The recorded exercise observed sensor isolation and stable recovery after detection. In the pre-freeze restart trials, FlightSW adopted a replay-checked result from the new session and rejected advice from the revoked session. Repeated guest tests also recorded missing flight cycles. Formal acceptance is pending on the frozen candidate. [Restart evidence](evidence-index.md#trained-advisor-recovery) · [Timing scope](limitations.md)
- **OPS-SAT offline inference.** The separate FFN uses the dataset authors' split. It fits preprocessing on training data and freezes the classification threshold on validation data before applying it to the published test split. Linux and QNX replay labels matched and scores met the configured tolerance. [Training](../../FprimeQnxReference/test/m4/train.py) · [Replay checker](../../FprimeQnxReference/test/m4/compare.py) · [OPSSAT-AD v2](https://doi.org/10.5281/zenodo.15108715)

### OPS-SAT model quality

The Linux replay produced average precision (AP) of 0.937 and Matthews correlation coefficient (MCC) of 0.869 on the published test split. The paper reports precision-recall area of 0.979 and MCC of 0.932 for its all-channel FCNN. The project and paper use their own training and threshold procedures. These figures describe offline classifier quality. [Pinned project experiment](https://github.com/D1349375/fprime-qnx/commit/c472851c4f391c56ef0c716962cb31ff3ba10ab9) · [Paper, Table 3](https://www.nature.com/articles/s41597-025-05035-3/tables/3)
