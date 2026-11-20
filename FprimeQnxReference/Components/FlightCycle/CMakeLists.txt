register_fprime_module(
    AUTOCODER_INPUTS "${CMAKE_CURRENT_LIST_DIR}/FlightCycle.fpp"
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/FlightCycle.cpp"
    HEADERS "${CMAKE_CURRENT_LIST_DIR}/FlightCycle.hpp" "${CMAKE_CURRENT_LIST_DIR}/Recovery.hpp"
    DEPENDS Components_Link Svc_QnxTimer
)
