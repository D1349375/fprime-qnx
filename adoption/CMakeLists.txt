####
# 'adoption' project:
#
# Builds the unmodified-as-possible upstream F Prime `Ref` deployment (generated into Ref/ by scripts/import-ref.sh)
# against the FprimeQnx platform library. Mirrors lib/fprime/TestDeploymentsProject/CMakeLists.txt with paths adjusted.
####
cmake_policy(SET CMP0048 NEW)
cmake_minimum_required(VERSION 3.26)
project(Ref VERSION 1.0.0 LANGUAGES C CXX)

if (NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Ref/CMakeLists.txt")
    message(FATAL_ERROR "adoption/Ref is missing. Run scripts/import-ref.sh first.")
endif()

set(FPRIME_INCLUDE_FRAMEWORK_CODE OFF)
find_package(FPrime REQUIRED PATHS "${CMAKE_CURRENT_LIST_DIR}/../lib/fprime")

fprime_add_validation_flags()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../lib/fprime" "F-Prime")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Ref/")
