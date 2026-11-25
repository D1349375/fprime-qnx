#include "Os/Cpu.hpp"
#include "Os/Delegate.hpp"

#include <sys/neutrino.h>
#include <unistd.h>
#include <cstdint>
#include <limits>

namespace Os {
namespace {

class QnxCpu final : public CpuInterface {
  public:
    Status _getCount(FwSizeType& cpuCount) override {
        const long count = sysconf(_SC_NPROCESSORS_CONF);
        if (count <= 0 || static_cast<uint64_t>(count) > std::numeric_limits<FwSizeType>::max()) {
            return Status::ERROR;
        }
        cpuCount = static_cast<FwSizeType>(count);
        return Status::OP_OK;
    }

    Status _getTicks(Ticks& ticks, FwSizeType cpuIndex) override {
        FwSizeType count = 0;
        if (_getCount(count) != Status::OP_OK || cpuIndex >= count || cpuIndex >= std::numeric_limits<int>::max()) {
            return Status::ERROR;
        }

        // procnto's idle thread IDs start at one and follow the zero-based CPU indices.
        const int idleClock = ClockId(SYSMGR_PID, static_cast<int>(cpuIndex) + 1);
        uint64_t idleNs = 0;
        uint64_t totalNs = 0;
        if (idleClock == -1 || ClockTime(idleClock, nullptr, &idleNs) != 0 ||
            ClockTime(CLOCK_MONOTONIC, nullptr, &totalNs) != 0 || idleNs > totalNs) {
            return Status::ERROR;
        }

        // Sample idle time before the elapsed time, with one millisecond per tick.
        constexpr uint64_t NANOSECONDS_PER_TICK = 1000000;
        const uint64_t totalTicks = totalNs / NANOSECONDS_PER_TICK;
        if (totalTicks > std::numeric_limits<FwSizeType>::max()) {
            return Status::ERROR;
        }
        ticks.used = static_cast<FwSizeType>((totalNs - idleNs) / NANOSECONDS_PER_TICK);
        ticks.total = static_cast<FwSizeType>(totalTicks);
        return Status::OP_OK;
    }

    CpuHandle* getHandle() override { return &m_handle; }

  private:
    CpuHandle m_handle;
};

}  // namespace

CpuInterface* CpuInterface::getDelegate(CpuHandleStorage& alignedNewMemory) {
    return Delegate::makeDelegate<CpuInterface, QnxCpu>(alignedNewMemory);
}

}  // namespace Os
