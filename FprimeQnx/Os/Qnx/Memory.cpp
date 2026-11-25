#include "Os/Delegate.hpp"
#include "Os/Memory.hpp"

#include <sys/stat.h>
#include <sys/syspage.h>
#include <cstdint>
#include <cstring>
#include <limits>

namespace Os {
namespace {

class QnxMemory final : public MemoryInterface {
  public:
    Status _getUsage(Usage& usage) override {
        // Match pidin info: /proc reports available bytes and asinfo describes installed RAM.
        struct stat available {};
        if (stat("/proc", &available) != 0 || available.st_size < 0) {
            return Status::ERROR;
        }

        const auto elementSize = SYSPAGE_ELEMENT_SIZE(asinfo);
        if (elementSize < sizeof(asinfo_entry)) {
            return Status::ERROR;
        }
        const auto entryCount = SYSPAGE_ENTRY_SIZE(asinfo) / elementSize;
        const char* const names = SYSPAGE_ENTRY(strings)->data;
        uint64_t total = 0;
        constexpr uint64_t MAX_BYTES = std::numeric_limits<FwSizeType>::max();
        for (size_t index = 0; index < entryCount; ++index) {
            const auto* entry = SYSPAGE_ARRAY_IDX(asinfo, index);
            if (std::strcmp(names + entry->name, "ram") != 0) {
                continue;
            }
            // end is inclusive. Check that the range and its sum fit in the public byte counter.
            if (entry->end < entry->start || entry->end - entry->start >= MAX_BYTES - total) {
                return Status::ERROR;
            }
            total += entry->end - entry->start + 1;
        }

        const auto free = static_cast<uint64_t>(available.st_size);
        if (total == 0 || free > total) {
            return Status::ERROR;
        }
        usage.used = static_cast<FwSizeType>(total - free);
        usage.total = static_cast<FwSizeType>(total);
        return Status::OP_OK;
    }

    MemoryHandle* getHandle() override { return &m_handle; }

  private:
    MemoryHandle m_handle;
};

}  // namespace

MemoryInterface* MemoryInterface::getDelegate(MemoryHandleStorage& alignedNewMemory) {
    return Delegate::makeDelegate<MemoryInterface, QnxMemory>(alignedNewMemory);
}

}  // namespace Os
