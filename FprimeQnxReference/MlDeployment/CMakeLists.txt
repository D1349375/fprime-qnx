add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Top")

register_fprime_deployment(
    MlAdvisor
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/Main.cpp"
    DEPENDS MlDeployment_Top
)

set(FPRIME_QNX_M4_SYSROOT "" CACHE PATH "QNX x86-64 E6 APK overlay for the optional FFN")
if(FPRIME_QNX_M4_SYSROOT)
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "QNX" OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
        message(FATAL_ERROR "The M4 APK overlay is supported on QNX x86-64")
    endif()

    set(m4_include "${FPRIME_QNX_M4_SYSROOT}/usr/include")
    set(m4_lib "${FPRIME_QNX_M4_SYSROOT}/usr/lib")
    foreach(dependency IN ITEMS "${m4_include}/mlpack.hpp" "${m4_lib}/libarmadillo.so" "${m4_lib}/libopenblas.so")
        if(NOT EXISTS "${dependency}")
            message(FATAL_ERROR "Missing M4 APK dependency: ${dependency}")
        endif()
    endforeach()
    add_library(m4-ffn STATIC Ffn.cpp)
    set_target_properties(m4-ffn PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES)
    target_include_directories(m4-ffn PRIVATE "${CMAKE_CURRENT_LIST_DIR}/..")
    # The overlay also contains links to the SDK's C headers. QCC must search
    # its libc++ wrappers first to avoid picking up C macros in C++ headers.
    target_compile_options(m4-ffn PRIVATE "-Wp,-idirafter,${m4_include}" -O2)
    target_compile_definitions(m4-ffn PRIVATE _QNX_SOURCE ARMA_DONT_USE_OPENMP)
    target_link_libraries(m4-ffn PUBLIC "${m4_lib}/libarmadillo.so" "${m4_lib}/libopenblas.so")
    target_link_options(m4-ffn INTERFACE "LINKER:-rpath-link,${m4_lib}")

    target_compile_definitions(MlAdvisor PRIVATE FPRIME_QNX_ML_ADVISOR)
    target_link_libraries(MlAdvisor PRIVATE m4-ffn)

    add_executable(m4-replay ../test/m4/replay.cpp)
    target_include_directories(m4-replay PRIVATE "${CMAKE_CURRENT_LIST_DIR}/..")
    target_compile_definitions(m4-replay PRIVATE _QNX_SOURCE)
    target_compile_options(m4-replay PRIVATE -O2)
    target_link_libraries(m4-replay PRIVATE m4-ffn)
    set_target_properties(MlAdvisor m4-replay PROPERTIES SKIP_BUILD_RPATH TRUE)
endif()
