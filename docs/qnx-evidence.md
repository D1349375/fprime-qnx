# QNX evidence index

The target validation uses project commit `eef1b35a036cd7c2de7db217b548eb80867e98fd` and F Prime v4.4.2 at `f22ce8f2f2943e641d454e9daa7f129e6c878d32`. M5 reproduced the Ref/GDS check and trained-advisor pilot on Ubuntu 24.04.5 under WSL2, using QNX SDP 8.0.6 and `qcc` GCC 12.2.0. The target was QNX 8.0.0 x86-64 on QEMU 8.2.2/KVM with two vCPUs and 1536 MiB of memory. [Tested commit](https://github.com/D1349375/fprime-qnx/commit/eef1b35a036cd7c2de7db217b548eb80867e98fd) · [Setup and commands](../README.md)

| Claim | Relevant implementation | Reproduce and check |
| --- | --- | --- |
| The upstream `Ref` deployment cross-builds, boots on QNX, and exchanges commands and telemetry with GDS. | [Ref patch](../adoption/ref-qnx.patch) · [QNX toolchain](../FprimeQnx/cmake/toolchain/qnx-x86_64.cmake) · [Pulse-driven timer](../FprimeQnx/Svc/QnxTimer/QnxTimer.cpp) | `scripts/clean-rebuild.sh`. Check for a new QNX guest, `NoOpReceived`, `OpCodeCompleted`, and rate group 1 telemetry. [Inspect the run](#ref-and-gds) |
| The simulated flight loop exchanges snapshots and advice outside its periodic submission path. | [Flight cycle](../FprimeQnxReference/Components/FlightCycle/FlightCycle.cpp) · [QNX native message driver](../FprimeQnx/Drv/QnxMsgDriver/QnxMsgDriver.cpp) | `scripts/m2-check.sh qnx`. Check native IPC activity, bounded queue behavior when the advisor falls behind, and flight submissions after the advisor stops. See `flight.csv` and `summary.txt`. |
| With the trained FFN loaded, the Q1 fault exercises FDIR takeover, process restart and session validation. | [SLM configuration](../FprimeQnxReference/qnx/m3-slm.xml.in) · [Recovery gate](../FprimeQnxReference/Components/FlightCycle/Recovery.hpp) · [FFN inference](../FprimeQnxReference/MlDeployment/Ffn.cpp) | `scripts/m4-check.sh <sysroot> adcs-pilot`. Require `PASS` in the pilot's `2001-q1-01` row, a replacement advisor, rejection of the old session, and a replay-checked result from the new one. [Inspect the run](#trained-advisor-fault-and-recovery) |
| Q1 and Q2 exercise the two SLM repair policies with a deterministic advisor. | [SLM template](../FprimeQnxReference/qnx/m3-slm.xml.in) · [Fault harness](../scripts/m3-check.sh) | `scripts/m3-check.sh 1`. Both cases require FDIR takeover. Q1 requires a replacement session. Q2 requires continued FDIR through the observation window without an advisor restart. Check `results.tsv` and each case's `death.csv` and `slm.log`. |
| The trained advisor and FDIR control are evaluated against the same simulated sensor bias. | [Training and holdout split](../FprimeQnxReference/test/m4/train.py) · [ADCS assessment](../FprimeQnxReference/test/m4/assess-adcs.py) | `scripts/m4-check.sh <sysroot> adcs`. Examine paired held-out seeds and the nominal, bias and crash cases. `adcs.json` records the alert, gate decision, sensor isolation and stable recovery markers. |
| The separate OPS-SAT model produces consistent Linux and QNX inference on the author's test split. | [Replay program](../FprimeQnxReference/test/m4/replay.cpp) · [Score comparison](../FprimeQnxReference/test/m4/compare.py) | `scripts/m4-check.sh <sysroot> opssat`. Check that `replay/comparison.csv` covers the 529 published test cases, scores meet the configured tolerances and labels match. Read `replay/summary.txt` for failures and deviations. [OPSSAT-AD v2](https://doi.org/10.5281/zenodo.15108715) |
| Upstream OSAL suites run against the QNX platform. | [Platform selection](../FprimeQnx/cmake/platform/QNX.cmake) · [OSAL harness](../scripts/osal-check.sh) | `scripts/osal-check.sh`. Read the per-suite results and target logs. Record passing, failed and skipped cases along with the features covered by stubs. [Portability notes](upstream-notes.md) |

## Ref and GDS

After the [clean Ref build](../README.md#reproduce-m1), open `logs/source.log` for the checked-out revisions, then `logs/build.log`, `logs/image.log`, and `logs/ref-gds.log` for the build, guest image, and GDS check. The GDS probe reports the decoded events and rate group channel in its per-attempt logs.

The validated command round trip is `CMD_NO_OP` → `NoOpReceived` and `OpCodeCompleted`. Look for `Ref.rateGroup1Comp.RgMaxTime` in the same run. The sample confirms that rate group telemetry returns from the target.

## Trained-advisor fault and recovery

In the saved M5 pilot, FlightSW continued submitting estimates after the advisor exited. FDIR took over, the gate rejected a result from the old session with `R2_SESSION`, and FlightSW accepted the first replay-checked result from the replacement session.

After the [ADCS pilot](../README.md#reproduce-m4), read the printed run directory's `source.txt`, `target-uname.txt`, and `results.tsv`. Use `2001-q1-01/config.txt` for the flight and recovery requirements.

1. Check `death.csv` and `slm.log` for the advisor exit and replacement process.
2. Check `flight.csv` and `timing.txt` for the expected flight submissions and the switch to independent FDIR. The timing checker counts a missing release as a miss.
3. Check `link.csv` and `adcs.json` for the old-session rejection and the first valid result from the replacement session, tied to a fresh flight snapshot. The ADCS checker compares that live result with the offline replay.

To recompute the Q1 decision, set `M4_RUN_DIR` to the pilot directory and use the same Python environment as the runner.

```bash
q1="$M4_RUN_DIR/2001-q1-01"
"$M4_PYTHON" -B FprimeQnxReference/test/int/check-m3.py "$q1"
"$M4_PYTHON" -B FprimeQnxReference/test/m4/assess-adcs.py "$M4_RUN_DIR/replay" "$q1"
```

Both rechecks must exit `0`. `check-m3.py` covers timing, fallback and rejoin. `assess-adcs.py` checks that the advisor output and its use by FlightSW agree with replay.

## Coverage and repeatability

- The confirmed M5 target is the x86-64 QEMU/KVM guest above. Earlier same-host pilot repeats recorded missing cycles or delayed advisor readiness. Keep the verdict and evidence for each run.
- The ADCS scenario tests a fixed simulated sensor offset. Its paired comparison observed the same first-alert cycle for FDIR and the FFN and later isolation and stable recovery in the FFN condition. OPS-SAT is offline replay on a separate dataset.
- The M1 OSAL baseline includes failed and skipped cases. Attach a revision to each OSAL report when comparing results. CPU and memory use upstream stubs. Stock POSIX UART coverage, AArch64 runtime, physical boards and a broader sensor fault set remain open. [Known port limitations](upstream-notes.md)

## Planned demonstration cues

The storyboard places the Ref/GDS round trip at 0:15, the trained-advisor fault and rejoin at 1:30, and the reproduction commands and x86-64 scope at 2:30. Link to the corresponding recorded footage when the submission video is available.
