register_fprime_module(
    AUTOCODER_INPUTS "${CMAKE_CURRENT_LIST_DIR}/FlightGround.fpp"
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/FlightGround.cpp"
    DEPENDS Components_FlightCycle
)
