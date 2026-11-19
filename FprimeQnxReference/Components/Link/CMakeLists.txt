register_fprime_module(
    AUTOCODER_INPUTS "${CMAKE_CURRENT_LIST_DIR}/HubLink.fpp"
    SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/HubLink.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/Protocol.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/Transport.cpp"
    HEADERS
        "${CMAKE_CURRENT_LIST_DIR}/HubLink.hpp"
        "${CMAKE_CURRENT_LIST_DIR}/Protocol.hpp"
        "${CMAKE_CURRENT_LIST_DIR}/SpscQueue.hpp"
        "${CMAKE_CURRENT_LIST_DIR}/Transport.hpp"
    DEPENDS Svc_GenericHub Drv_QnxMsgDriver
)
