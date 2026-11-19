####
# Svc/QnxTimer: pulse-driven rate group timer for QNX. Built only for the QNX platform.
####
restrict_platforms(QNX)

register_fprime_module(
  AUTOCODER_INPUTS
    "${CMAKE_CURRENT_LIST_DIR}/QnxTimer.fpp"
  SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/QnxTimer.cpp"
  HEADERS
    "${CMAKE_CURRENT_LIST_DIR}/QnxTimer.hpp"
)
