####
# qnx-x86_64.cmake:
#
# QNX SDP 8.0 toolchain for x86_64 targets (e.g. QEMU/KVM images built with mkqnximage).
# Usage: source <sdp>/qnxsdp-env.sh && fprime-util generate qnx-x86_64
####
set(QNX_ARCH "x86_64")
include("${CMAKE_CURRENT_LIST_DIR}/helpers/qnx-base.cmake")
