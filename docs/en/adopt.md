
# Adopt FprimeQnx in an existing deployment

The platform library supplies the QNX platform and toolchain files, POSIX OSAL selection, a pulse-driven rate-group timer and an optional native IPC driver. The [Ref adoption patch](../../adoption/ref-qnx.patch) shows the changes for a deployment that already uses rate groups and F Prime GDS. [F Prime platform porting guide](https://fprime.jpl.nasa.gov/v4.4.0/docs/how-to/integrate/porting-guide/)

1. **Register the library.** Add the directory that contains `FprimeQnx/library.cmake` to `library_locations` in the deployment project's `settings.ini`. Keep `framework_path` on the pinned F Prime release. The Ref example uses `../lib/fprime` and `../FprimeQnx`. [Example settings](../../adoption/settings.ini)
2. **Select the toolchain.** With the local SDP and F Prime environment active, run `fprime-util generate qnx-x86_64` and `fprime-util build qnx-x86_64 --jobs 2` from the F Prime project root. The toolchain reads `QNX_HOST` and `QNX_TARGET` from that environment. [x86-64 toolchain](../../FprimeQnx/cmake/toolchain/qnx-x86_64.cmake)
3. **Use the QNX timer.** If the deployment uses `Svc.LinuxTimer`, change the instance type to `Svc.QnxTimer` and preserve its cycle output connections to the rate group driver. The Ref patch keeps the instance name and its start/quit API. [Timer interface](../../FprimeQnx/Svc/QnxTimer/QnxTimer.fpp)
4. **Review optional components and verify the target.** The Ref patch removes `wasmSeq`, its connections and packet entries because that component requires a QNX Rust toolchain. It keeps `cmdSeq`. In your deployment, review other platform-specific drivers and components, then run the applicable GDS, hardware and integration checks. [Current port limitations](limitations.md)

Start by running the [Ref clean rebuild](reproduce.md#ref-and-gds-v2-and-v2b). It imports the pinned upstream Ref, applies the example patch, and verifies command, event and telemetry paths in a new QNX guest. For your own deployment, choose and validate the target board or guest image, driver implementations, scheduling, privileges, ground dictionary and end-to-end mission behavior.
