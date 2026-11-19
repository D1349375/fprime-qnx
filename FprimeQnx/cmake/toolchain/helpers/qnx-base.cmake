####
# qnx-base.cmake:
#
# Shared settings for the QNX SDP 8.0 toolchains. Callers set QNX_ARCH (x86_64 or aarch64le) before including this file.
#
# The QNX SDK location is taken from the environment set up by `source qnxsdp-env.sh`, so no host path is written into
# the repository. Both QNX_HOST and QNX_TARGET must be set.
####
if (NOT DEFINED QNX_ARCH)
    message(FATAL_ERROR "[QNX] QNX_ARCH must be set before including qnx-base.cmake")
endif()
foreach (QNX_ENV_VAR IN ITEMS QNX_HOST QNX_TARGET)
    if (NOT DEFINED ENV{${QNX_ENV_VAR}})
        message(FATAL_ERROR "[QNX] ${QNX_ENV_VAR} is not set. Run `source <sdp>/qnxsdp-env.sh` before generating.")
    endif()
endforeach()

set(CMAKE_SYSTEM_NAME QNX)
set(CMAKE_SYSTEM_VERSION 8.0.0)
set(CMAKE_SYSTEM_PROCESSOR "${QNX_ARCH}")

set(QNX_HOST "$ENV{QNX_HOST}")
set(QNX_TARGET "$ENV{QNX_TARGET}")

# qcc selects the target with -V<compiler>,<target>; CMake's QCC support passes CMAKE_<LANG>_COMPILER_TARGET this way.
set(CMAKE_C_COMPILER "${QNX_HOST}/usr/bin/qcc")
set(CMAKE_C_COMPILER_TARGET "gcc_nto${QNX_ARCH}")
set(CMAKE_CXX_COMPILER "${QNX_HOST}/usr/bin/q++")
set(CMAKE_CXX_COMPILER_TARGET "gcc_nto${QNX_ARCH}_cxx")

set(CMAKE_SYSROOT "${QNX_TARGET}")
set(CMAKE_FIND_ROOT_PATH "${QNX_TARGET}" "${QNX_TARGET}/${QNX_ARCH}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# BOTH: the F Prime CMake package itself lives on the host (lib/fprime), not in the QNX sysroot
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
