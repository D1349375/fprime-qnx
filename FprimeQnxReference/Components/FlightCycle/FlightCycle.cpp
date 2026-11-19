#include "Components/FlightCycle/FlightCycle.hpp"

#include <algorithm>
#include <cmath>

namespace M2 {
namespace {

SensorReadings sampleSensors(std::uint64_t cycle) {
    // Six ideal cosine sensors on the positive and negative axes.
    const double angle = static_cast<double>(cycle % 360) * 0.017453292519943295;
    const double x = 0.8 * std::cos(angle);
    const double y = 0.8 * std::sin(angle);
    const double z = 0.6;
    const auto intensity = [](double projection) {
        return static_cast<std::uint16_t>(std::max(0.0, projection) * 1000.0 + 0.5);
    };
    return {{intensity(x), intensity(-x), intensity(y), intensity(-y), intensity(z), intensity(-z)}};
}

Estimate estimateSun(const SensorReadings& readings) {
    const double x = static_cast<double>(readings[0]) - readings[1];
    const double y = static_cast<double>(readings[2]) - readings[3];
    const double z = static_cast<double>(readings[4]) - readings[5];
    const double magnitude = std::sqrt(x * x + y * y + z * z);
    if (magnitude == 0) {
        return {};
    }
    return {x / magnitude, y / magnitude, z / magnitude, true};
}

}  // namespace

FlightCycle::FlightCycle(const char* name) : FlightCycleComponentBase(name) {}

void FlightCycle::schedule(Handoff& handoff,
                           Svc::QnxTimer& timer,
                           std::uint64_t firstRelease,
                           std::uint64_t limit) {
    m_handoff = &handoff;
    m_timer = &timer;
    m_firstRelease = firstRelease;
    m_limit = limit;
}

void FlightCycle::run_handler(FwIndexType, U32) {
    const auto start = monotonicNs();
    if (start < m_firstRelease) {
        return;
    }
    const auto cycle = 1 + (start - m_firstRelease) / PeriodNs;
    if (m_limit != 0 && cycle > m_limit) {
        m_complete = true;
        m_timer->quit();
        return;
    }
    if (cycle <= m_lastCycle) {
        return;
    }

    Advice candidate;
    if (m_handoff->results.pop(candidate)) {
        m_advice = candidate;
    }
    if (m_advice.session != m_handoff->session.load(std::memory_order_acquire) ||
        start < m_advice.sampledNs || start - m_advice.sampledNs > FreshnessNs) {
        m_advice = {};
    }
    const Snapshot snapshot{cycle, start, sampleSensors(cycle)};
    m_output = estimateSun(snapshot.sensors);
    const auto finish = monotonicNs();

    if (!m_handoff->snapshots.push(snapshot)) {
        ++m_snapshotDrops;
    }
    const CycleRecord record{cycle, m_firstRelease + (cycle - 1) * PeriodNs, start, finish,
                             m_snapshotDrops, m_output, m_advice};
    if (!m_handoff->records.push(record)) {
        ++m_recordDrops;
    }
    m_lastCycle = cycle;
    if (cycle == m_limit) {
        m_complete = true;
        m_timer->quit();
    }
}

}  // namespace M2
