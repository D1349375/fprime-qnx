add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Top")

register_fprime_deployment(
    MlAdvisor
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/Main.cpp"
    DEPENDS MlDeployment_Top
)
