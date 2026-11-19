####
# qnx-aarch64le.cmake:
#
# QNX SDP 8.0 toolchain for 64-bit ARM targets (e.g. Raspberry Pi 4/5 running QNX). Build-only; not verified on target.
# Usage: source <sdp>/qnxsdp-env.sh && fprime-util generate qnx-aarch64le
####
set(QNX_ARCH "aarch64le")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/qnx-base.cmake")
