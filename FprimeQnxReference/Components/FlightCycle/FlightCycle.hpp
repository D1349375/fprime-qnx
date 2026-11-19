#ifndef M2_FLIGHT_CYCLE_HPP
#define M2_FLIGHT_CYCLE_HPP

#include "Components/FlightCycle/FlightCycleComponentAc.hpp"
#include "Components/Link/Protocol.hpp"
#include "Components/Link/SpscQueue.hpp"
#include "Svc/QnxTimer/QnxTimer.hpp"

namespace M2 {

constexpr unsigned SnapshotCapacity = 4;

struct Snapshot {
    std::uint64_t cycle = 0;
    std::uint64_t sampledNs = 0;
    SensorReadings sensors{};
};

struct Advice {
    std::uint64_t session = 0;
    std::uint64_t cycle = 0;
    std::uint64_t sampledNs = 0;
    bool alert = false;
};

struct Estimate {
    double x = 0;
    double y = 0;
    double z = 0;
    bool valid = false;
};

struct CycleRecord {
    std::uint64_t cycle;
    std::uint64_t release;
    std::uint64_t start;
    std::uint64_t finish;
    std::uint64_t snapshotDrops;
    Estimate output;
    Advice advice;
};

struct Handoff {
    SpscQueue<Snapshot, SnapshotCapacity> snapshots;
    SpscQueue<Advice, 4> results;
    SpscQueue<CycleRecord, 256> records;
    static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
                  "flight session lookup needs lock-free 64-bit loads");
    std::atomic<std::uint64_t> session{0};
};

class FlightCycle final : public FlightCycleComponentBase {
  public:
    explicit FlightCycle(const char* name);
    void schedule(Handoff& handoff, Svc::QnxTimer& timer, std::uint64_t firstRelease, std::uint64_t limit);
    std::uint64_t lastCycle() const { return m_lastCycle; }
    std::uint64_t recordDrops() const { return m_recordDrops; }
    bool complete() const { return m_complete; }

  private:
    void run_handler(FwIndexType port, U32 context) override;

    Handoff* m_handoff = nullptr;
    Svc::QnxTimer* m_timer = nullptr;
    Estimate m_output{};
    Advice m_advice{};
    std::uint64_t m_firstRelease = 0;
    std::uint64_t m_limit = 0;
    std::uint64_t m_lastCycle = 0;
    std::uint64_t m_snapshotDrops = 0;
    std::uint64_t m_recordDrops = 0;
    bool m_complete = false;
};

}  // namespace M2

#endif
