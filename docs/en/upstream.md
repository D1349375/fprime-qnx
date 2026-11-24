
# Upstream status

F Prime on QNX is a standalone port repository with `nasa/fprime` as a Git submodule. Project builds use release `v4.4.2` at `f22ce8f2f2943e641d454e9daa7f129e6c878d32`. The source review below used the distinct upstream `devel` revision `633c89d5b7f67a547160712a38efa58047566512`. [NASA/JPL F Prime](https://github.com/nasa/fprime) · [Pinned release source](https://github.com/nasa/fprime/tree/f22ce8f2f2943e641d454e9daa7f129e6c878d32) · [Reviewed development source](https://github.com/nasa/fprime/tree/633c89d5b7f67a547160712a38efa58047566512)

## Contribution status

| Work | Status as of 2026-11-25 |
| --- | --- |
| U0 platform-library and reference deployment discussion | Posted on 2026-11-24 as [discussion #6436](https://github.com/nasa/fprime/discussions/6436) in the General category. No replies yet. |
| U4 POSIX UART portability issue | Posted on 2026-11-24 as [issue #6437](https://github.com/nasa/fprime/issues/6437) with the standalone header reproducer. Maintainers added the `bug` and `Platforms` labels. No replies yet. |
| Upstream pull request | None submitted for this port. A pull request for U4 waits for the maintainers to accept the issue, following the upstream contribution process. Project-repository reviews track the port itself. |

The upstream guide describes supported platforms, community reference projects, and CI requirements. The pinned contribution process asks for an issue and Change Control Board (CCB) approval before implementing a corresponding pull request. The U0 discussion asks about the community add-on layout and external CI. [Supported platforms](https://fprime.jpl.nasa.gov/latest/docs/user-manual/framework/supported-platforms/) · [Contribution process](https://github.com/nasa/fprime/blob/633c89d5b7f67a547160712a38efa58047566512/CONTRIBUTING.md#code-contribution-process) · [External CI interface](https://github.com/nasa/fprime/blob/633c89d5b7f67a547160712a38efa58047566512/.github/actions/ext-ci/README.md)

## Development-revision recheck

| Area | Verified scope and candidate work |
| --- | --- |
| U0 platform integration | The Ref command, events and rate-group telemetry were verified on the project's pinned release in the x86-64 guest. The upstream development revision was reviewed separately. [Ref evidence](evidence-index.md#target-and-host-coverage) |
| U2 optional Rust in Ref | The reviewed Ref still includes `wasmSeq` and its CMake setup rejects an unavailable Rust toolchain. Optional Rust remains a candidate. [Prior issue #6034](https://github.com/nasa/fprime/issues/6034) · [Merged PR #6212](https://github.com/nasa/fprime/pull/6212) · [Reviewed Ref CMake](https://github.com/nasa/fprime/blob/633c89d5b7f67a547160712a38efa58047566512/TestDeploymentsProject/Ref/CMakeLists.txt) |
| U4 POSIX UART | With SDP 8.0.6 and `q++ -Vgcc_ntox86_64`, standalone header probes confirmed that `CRTSCTS` and `B230400` are unavailable and that `IHFLOW \| OHFLOW` compiles. The complete driver, fallback behavior and physical UART remain unverified. [Driver](https://github.com/nasa/fprime/blob/633c89d5b7f67a547160712a38efa58047566512/Drv/PosixUartDriver/PosixUartDriver.cpp) · [Related issue #5698](https://github.com/nasa/fprime/issues/5698) · [Related PR #5811](https://github.com/nasa/fprime/pull/5811) |
| U3 POSIX IP configuration | Source inspection found socket paths using POSIX headers and an OS guard in `IpCfg.hpp`. Isolated preprocessing confirmed the guard. A complete QNX build of the development-revision driver remains open. [Reviewed IP source](https://github.com/nasa/fprime/tree/633c89d5b7f67a547160712a38efa58047566512/Drv/Ip) |
| U1 OSAL tests | Source review found the free-space assumption for the root filesystem and the `system_clock` boundary comparison. Task and queue tests have changed since v4.4.2. A QNX run of this development-revision suite remains open. The [local portability patch](../../adoption/osal-test-portability.patch) is for v4.4.2. |

The [original v4.4.2 adoption notes](../upstream-notes.md) describe the port's local CMake and OSAL choices.
