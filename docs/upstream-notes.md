# Upstream notes: F Prime v4.4.2 on QNX 8.0

Things found while building the upstream `Ref` deployment for QNX SDP 8.0 (x86_64) with the FprimeQnx platform
library. Each item says what FprimeQnx does today and what an upstream change could look like. None of these require
modifying the pinned `lib/fprime` submodule.

## 1. OS whitelist gates around POSIX socket and clock code

**Where.** `Drv/Ip/IpSocket.hpp`, `Drv/Ip/IpSocket.cpp`, `Drv/Ip/TcpClientSocket.cpp`, `Drv/Ip/TcpServerSocket.cpp`,
`Drv/Ip/UdpSocket.cpp`, `default/config/IpCfg.hpp`, `default/config/Os/RawTimeSource.hpp`.

**What happens.** These files select headers and clock IDs with `#if defined TGT_OS_TYPE_LINUX || TGT_OS_TYPE_DARWIN`
(or VxWorks) and fall through to `#error OS not supported for IP Socket Communications` otherwise. The code behind the
Linux branch is plain POSIX/BSD sockets and `clock_gettime`, all of which QNX provides.

**FprimeQnx today.** `cmake/platform/QNX.cmake` defines `TGT_OS_TYPE_LINUX` in addition to `TGT_OS_TYPE_QNX`, so QNX
takes the Linux branches. Linux-only code elsewhere stays excluded because it is gated on `__GLIBC__`
(`Os/Posix/Task.cpp`) or on `CMAKE_SYSTEM_NAME` at the CMake level.

**Upstream candidate.** Add `|| defined(TGT_OS_TYPE_QNX)` to those gates, or gate on a POSIX feature macro instead of an
OS list. Note that several gates are written `#elif defined TGT_OS_TYPE_LINUX || TGT_OS_TYPE_DARWIN`, where the second
operand is not wrapped in `defined()`; it only works because an undefined macro evaluates to 0.

## 2. `Drv/PosixUartDriver` uses non-POSIX termios names

**Where.** `Drv/PosixUartDriver/PosixUartDriver.cpp` lines 119 and 149 (v4.4.2).

**What happens.** `CRTSCTS` (hardware flow control) and `B230400` and higher baud constants are Linux/BSD extensions,
not POSIX. QNX uses `IHFLOW | OHFLOW` for hardware flow control and accepts numeric baud rates in `cfsetispeed` /
`cfsetospeed`.

**FprimeQnx today.** `library.cmake` marks `Drv_PosixUartDriver` `EXCLUDE_FROM_ALL` on QNX. `Ref` does not use it.

**Upstream candidate.** Guard the flow-control flag and each extended baud constant with `#ifdef`, falling back to
`IHFLOW | OHFLOW` and numeric rates where available.

## 3. `Svc/LinuxTimer` is restricted to Linux and Darwin

**Where.** `Svc/LinuxTimer/CMakeLists.txt` (`restrict_platforms(Linux Darwin)`); `Ref` wires its rate group driver to it.

**FprimeQnx today.** `Svc/QnxTimer` provides the same `startTimer()` / `quit()` API using `timer_create` with a pulse
event and `MsgReceivePulse`. Adopting it in `Ref` is a one-line instance type change (`adoption/ref-qnx.patch`).

## 4. `Svc/WasmSequencer` needs a Rust toolchain for the target

**Where.** `Svc/WasmSequencer/CMakeLists.txt` requires cargo >= 1.87; `Ref` instantiates `wasmSeq`.

**What happens.** When cargo is not found the module is skipped, but `Ref`'s topology still references
`Svc.WasmSequencer`, so dictionary generation fails with `symbol WasmSequencer is not defined`. This also happens on a
native Linux host without Rust. Rust's QNX targets (`x86_64-pc-nto-qnx800`, `aarch64-unknown-nto-qnx800`) are tier 3.

**FprimeQnx today.** `adoption/ref-qnx.patch` removes the `wasmSeq` instance, its connections, and its telemetry
channels. `cmdSeq` (`Svc.CmdSequencer`) remains.

**Upstream candidate.** Make `Ref`'s `wasmSeq` instance conditional, or document Rust as a hard requirement for `Ref`.
