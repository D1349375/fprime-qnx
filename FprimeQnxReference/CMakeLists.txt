cmake_minimum_required(VERSION 3.26)
project(FprimeQnxReference VERSION 1.0.0 LANGUAGES C CXX)

set(FPRIME_INCLUDE_FRAMEWORK_CODE OFF)
find_package(FPrime REQUIRED PATHS "${CMAKE_CURRENT_LIST_DIR}/../lib/fprime")
fprime_add_validation_flags()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../lib/fprime" "F-Prime")

add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Components/Link")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Components/FlightCycle")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Components/FlightGround")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/FlightDeployment")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/MlDeployment")
