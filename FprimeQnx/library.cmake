####
# library.cmake:
#
# Manifest for the FprimeQnx F Prime library. Add this directory to `library_locations` in a project's settings.ini to
# use it. The platform and toolchain files under cmake/ are found by F Prime automatically.
#
# F Prime includes library manifests after the framework modules are registered, so framework targets exist here.
####
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Svc/QnxTimer/")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Svc/QnxProcessMonitor/")
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Drv/QnxMsgDriver/")

if (FPRIME_PLATFORM STREQUAL "QNX")
    add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/Os/Qnx/")

    # GoogleTest is built separately and does not inherit PlatformQnx's POSIX feature macro.
    foreach (QNX_GTEST_TARGET IN ITEMS gtest gtest_main gmock gmock_main)
        if (TARGET "${QNX_GTEST_TARGET}")
            target_compile_definitions("${QNX_GTEST_TARGET}" PRIVATE _QNX_SOURCE)
        endif()
    endforeach()
    if (TARGET PosixTaskTest)
        # Run the upstream POSIX cases without selecting Linux-only syscalls and priority tests.
        target_compile_options(PosixTaskTest PRIVATE -UTGT_OS_TYPE_LINUX)
    endif()

    # Framework modules that do not compile on QNX as of F Prime v4.4.2. They are left out of the default build so
    # `fprime-util build` succeeds; a deployment that depends on one still fails loudly at compile time.
    #  - Drv_PosixUartDriver: uses CRTSCTS and B230400, which QNX termios does not define (QNX uses IHFLOW/OHFLOW and
    #    accepts numeric baud rates). Upstream fix candidate, see docs/upstream-notes.md.
    foreach (QNX_UNSUPPORTED_MODULE IN ITEMS Drv_PosixUartDriver)
        if (TARGET "${QNX_UNSUPPORTED_MODULE}")
            set_target_properties("${QNX_UNSUPPORTED_MODULE}" PROPERTIES EXCLUDE_FROM_ALL TRUE)
            fprime_cmake_status("[FprimeQnx] ${QNX_UNSUPPORTED_MODULE} excluded from the default build on QNX")
        endif()
    endforeach()
endif()
