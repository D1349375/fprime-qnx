#ifndef M2_FLIGHT_CYCLE_HPP
#define M2_FLIGHT_CYCLE_HPP

#include "Components/FlightCycle/FlightCycleComponentAc.hpp"
#include "Components/FlightCycle/Recovery.hpp"
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
    std::uint8_t action = 0;
    std::uint8_t channel = 0;
    std::uint64_t epoch = 0;
    const char* rejection = nullptr;
};

struct CycleRecord {
    std::uint64_t cycle;
    std::uint64_t release;
    std::uint64_t start;
    std::uint64_t finish;
    std::uint64_t snapshotDrops;
    Estimate output;
    Advice advice;
    bool submitted = false;
    bool fdir = false;
    bool rejoin = false;
    const char* fallback = "";
    const char* gate = "";
    const char* fdirGate = "";
    bool isolated = false;
    bool sensorFault = false;
    unsigned excluded = 0;
    Advice checked{};
    Estimate truth{};
    SensorReadings sensors{};
    std::uint64_t gateNs = 0;
    std::uint64_t fallbackNs = 0;
};

struct Handoff {
    SpscQueue<Snapshot, SnapshotCapacity> snapshots;
    SpscQueue<Advice, 4> results;
    SpscQueue<CycleRecord, 256> records;
    static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
                  "flight session lookup needs lock-free 64-bit loads");
    std::atomic<std::uint64_t> session{0};
    std::atomic<std::uint64_t> epoch{0};
};

class FlightCycle final : public FlightCycleComponentBase {
  public:
    explicit FlightCycle(const char* name);
    void schedule(Handoff& handoff, Svc::QnxTimer& timer, EstimateReceiver& receiver,
                  std::uint64_t firstRelease, std::uint64_t limit, Scenario scenario);
    std::uint64_t lastCycle() const { return m_lastCycle; }
    std::uint64_t recordDrops() const { return m_recordDrops; }
    bool complete() const { return m_complete; }

  private:
    void run_handler(FwIndexType port, U32 context) override;

    void recover(const Snapshot& snapshot, CycleRecord& record);
    void fallBack(CycleRecord& record, const char* reason, bool revoke);
    bool countRejection(std::uint64_t now);

    Handoff* m_handoff = nullptr;
    Svc::QnxTimer* m_timer = nullptr;
    Scenario m_scenario = Scenario::Legacy;
    Recovery m_recovery;
    EstimateReceiver* m_receiver = nullptr;
    std::array<std::uint64_t, RejectionLimit + 1> m_rejections{};
    unsigned m_nextRejection = 0;
    std::uint64_t m_isolatedUntil = 0;
    bool m_sensorFaultLogged = false;
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
