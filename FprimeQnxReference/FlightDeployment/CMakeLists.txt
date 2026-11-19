add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Top")

register_fprime_deployment(
    FlightSW
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/Main.cpp"
    DEPENDS FlightDeployment_Top
)
