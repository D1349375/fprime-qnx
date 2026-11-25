register_fprime_implementation(
    Os_Cpu_Qnx
    IMPLEMENTS Os_Cpu
    SOURCES "Cpu.cpp"
    DEPENDS Os_Cpu Fw_Types
)

register_fprime_implementation(
    Os_Memory_Qnx
    IMPLEMENTS Os_Memory
    SOURCES "Memory.cpp"
    DEPENDS Os_Memory Fw_Types
)

register_fprime_ut(
    QnxSystemResourcesTest
    SOURCES "test/SystemResourcesTest.cpp"
    CHOOSES_IMPLEMENTATIONS Os_Cpu_Qnx Os_Memory_Qnx
    DEPENDS Os_Cpu Os_Memory
)
