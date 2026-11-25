#include "Os/Cpu.hpp"
#include "Os/Memory.hpp"

#include <gtest/gtest.h>
#include <unistd.h>

TEST(QnxCpu, ReportsAccumulatingTicksForEachProcessor) {
    FwSizeType cpuCount = 0;
    ASSERT_EQ(Os::Cpu::getCount(cpuCount), Os::Cpu::Status::OP_OK);
    ASSERT_GT(cpuCount, 0U);
    for (FwSizeType cpuIndex = 0; cpuIndex < cpuCount; ++cpuIndex) {
        Os::Cpu::Ticks first{};
        Os::Cpu::Ticks second{};
        ASSERT_EQ(Os::Cpu::getTicks(first, cpuIndex), Os::Cpu::Status::OP_OK) << cpuIndex;
        ASSERT_GT(first.total, 0U);
        EXPECT_LE(first.used, first.total);
        ASSERT_EQ(usleep(20000), 0);
        ASSERT_EQ(Os::Cpu::getTicks(second, cpuIndex), Os::Cpu::Status::OP_OK) << cpuIndex;
        EXPECT_GT(second.total, first.total);
        EXPECT_LE(second.used, second.total);
    }
}

TEST(QnxCpu, RejectsOutOfRangeProcessor) {
    FwSizeType cpuCount = 0;
    Os::Cpu::Ticks sample{};
    ASSERT_EQ(Os::Cpu::getCount(cpuCount), Os::Cpu::Status::OP_OK);
    EXPECT_EQ(Os::Cpu::getTicks(sample, cpuCount), Os::Cpu::Status::ERROR);
}

TEST(QnxMemory, ReportsOccupiedAndTotalPhysicalBytes) {
    Os::Memory::Usage usage{};
    ASSERT_EQ(Os::Memory::getUsage(usage), Os::Memory::Status::OP_OK);
    EXPECT_GT(usage.used, 0U);
    EXPECT_GT(usage.total, 0U);
    EXPECT_LE(usage.used, usage.total);
}

int main(int argc, char** argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
