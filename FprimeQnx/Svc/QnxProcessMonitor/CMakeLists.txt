restrict_platforms(QNX)

register_fprime_module(
  AUTOCODER_INPUTS
    "${CMAKE_CURRENT_LIST_DIR}/QnxProcessMonitor.fpp"
  SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/QnxProcessMonitor.cpp"
  HEADERS
    "${CMAKE_CURRENT_LIST_DIR}/QnxProcessMonitor.hpp"
)
