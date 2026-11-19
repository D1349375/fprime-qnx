####
# QNX.cmake:
#
# F Prime platform file for QNX SDP 8.0 targets. Selected automatically when CMAKE_SYSTEM_NAME is QNX (set by the
# qnx-* toolchain files in this library).
#
# QNX is POSIX-compliant, so this platform reuses the unix platform types and the POSIX OSAL implementations, the same
# way the Linux and Darwin platform files do. QNX-specific pieces live alongside this file in the FprimeQnx library.
####
find_package(Threads REQUIRED)
set(FPRIME_USE_POSIX ON CACHE INTERNAL "Use POSIX implementations of OS features" FORCE)
set(FPRIME_HAS_SOCKETS ON CACHE INTERNAL "Indicates if sockets are available" FORCE)

# Reuse the unix PlatformTypes (pointer-size based) shared by Linux and Darwin
add_fprime_subdirectory("${FPRIME_FRAMEWORK_PATH}/cmake/platform/unix/Platform/")

register_fprime_config(
        PlatformQnx
    INTERFACE # No buildable files generated
    CHOOSES_IMPLEMENTATIONS
        # QNX provides working POSIX unnamed semaphores (sem_init, sem_timedwait)
        Os_CountingSemaphore_Posix
        # Os_Cpu and Os_Memory stay on the unix Stub selection until QNX implementations land in this library
    GLOBAL_IMPLICIT_DEPENDENCY
)
target_compile_definitions(PlatformQnx INTERFACE -DTGT_OS_TYPE_QNX)
# Compatibility shim: F Prime v4.4.2 gates its POSIX socket and clock code on an OS whitelist
# (`TGT_OS_TYPE_LINUX || TGT_OS_TYPE_DARWIN`) in Drv/Ip/*.cpp, Drv/Ip/*.hpp, default/config/IpCfg.hpp and
# default/config/Os/RawTimeSource.hpp. The code behind those gates is plain POSIX/BSD sockets, which QNX provides, so
# QNX takes the Linux branches. Linux-only code elsewhere is excluded independently: glibc checks (__GLIBC__) in
# Os/Posix/Task.cpp and CMake-level CMAKE_SYSTEM_NAME checks for Linux-only modules. Remove this once upstream
# gates recognize TGT_OS_TYPE_QNX (see docs/upstream-notes.md).
target_compile_definitions(PlatformQnx INTERFACE -DTGT_OS_TYPE_LINUX)
# F Prime compiles with strict -std=c++14/c99 (no GNU extensions), under which QNX headers hide POSIX declarations
# such as open(), fcntl(), and lstat(). _QNX_SOURCE exposes POSIX plus the QNX extensions (the QNX equivalent of
# glibc's _GNU_SOURCE).
target_compile_definitions(PlatformQnx INTERFACE -D_QNX_SOURCE)
# QNX keeps the BSD socket API in libsocket rather than libc
target_link_libraries(PlatformQnx INTERFACE socket)
