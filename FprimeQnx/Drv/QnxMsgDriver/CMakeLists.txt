restrict_platforms(QNX)

register_fprime_module(
    SOURCES "${CMAKE_CURRENT_LIST_DIR}/QnxMsgDriver.cpp"
    HEADERS "${CMAKE_CURRENT_LIST_DIR}/QnxMsgDriver.hpp"
)
target_compile_definitions(Drv_QnxMsgDriver PRIVATE _QNX_SOURCE)
