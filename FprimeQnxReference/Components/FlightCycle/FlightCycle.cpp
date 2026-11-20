#include "Components/FlightCycle/FlightCycle.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

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
                           EstimateReceiver& receiver,
                           std::uint64_t firstRelease,
                           std::uint64_t limit,
                           Scenario scenario) {
    m_handoff = &handoff;
    m_timer = &timer;
    m_receiver = &receiver;
    m_firstRelease = firstRelease;
    m_limit = limit;
    m_scenario = scenario;
}

void FlightCycle::fallBack(CycleRecord& record, const char* reason, bool revoke) {
    record.fallback = reason;
    record.fallbackNs = monotonicNs();
    m_advice = {};
    m_recovery.resetProposal();
    if (revoke) {
        m_handoff->epoch.fetch_add(1, std::memory_order_release);
    }
}

bool FlightCycle::countRejection(std::uint64_t now) {
    m_rejections[m_nextRejection] = now;
    m_nextRejection = (m_nextRejection + 1) % m_rejections.size();
    return m_rejections[m_nextRejection] != 0 && now - m_rejections[m_nextRejection] <= RejectionWindowNs;
}

void FlightCycle::recover(const Snapshot& snapshot, CycleRecord& record) {
    const auto now = snapshot.sampledNs;
    const auto& sensors = snapshot.sensors;
    m_recovery.observe(sensors);
    if (m_advice.session != 0 &&
        (m_advice.sampledNs > now || now - m_advice.sampledNs > FreshnessNs)) {
        fallBack(record, "RESULT_TIMEOUT", true);
    } else if (m_advice.session != 0 &&
               m_advice.session != m_handoff->session.load(std::memory_order_acquire)) {
        fallBack(record, "SESSION_CHANGED", false);
    }

    Advice candidate;
    if (record.fallbackNs == 0 && m_handoff->results.pop(candidate)) {
        record.checked = candidate;
        record.isolated = now < m_isolatedUntil;
        if (record.isolated) {
            record.gate = "R8_ISOLATED";
        } else if (candidate.rejection != nullptr) {
            record.gate = candidate.rejection;
        } else if (candidate.epoch != m_handoff->epoch.load(std::memory_order_acquire) ||
                   candidate.session != m_handoff->session.load(std::memory_order_acquire)) {
            record.gate = "R2_SESSION";
        } else if (candidate.sampledNs > now || now - candidate.sampledNs > FreshnessNs) {
            record.gate = "R2_STALE";
        } else {
            record.gate = m_recovery.evaluate(sensors, candidate.action, candidate.channel, false, now);
            // Valid result progress is separate from permission to execute its proposal.
            if (std::strcmp(record.gate, "R1_WHITELIST") != 0) {
                record.rejoin = m_advice.session == 0;
                m_advice = candidate;
            }
        }
        record.gateNs = monotonicNs();
        if (!record.isolated && record.gate[0] == 'R' && std::strcmp(record.gate, "R3_PERSISTENCE") != 0) {
            m_recovery.resetProposal();
            if (countRejection(now)) {
                m_rejections.fill(0);
                m_isolatedUntil = now + IsolationNs;
                record.isolated = true;
                fallBack(record, "GATE_ISOLATION", true);
            }
        }
    }
    record.isolated = now < m_isolatedUntil;
    record.fdir = m_advice.session == 0;
    const int channel = m_recovery.fdirCandidate();
    if (record.fdir && channel != NoChannel) {
        record.fdirGate = m_recovery.evaluate(sensors, ExcludeSunSensor, static_cast<unsigned>(channel), true, now);
    }
    record.advice = m_advice;
    record.excluded = m_recovery.excludedMask();
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

    const bool legacy = m_scenario == Scenario::Legacy;
    const Snapshot snapshot{cycle, start, legacy ? sampleSensors(cycle) : recoverySensors(m_scenario, cycle)};
    CycleRecord record{};
    record.cycle = cycle;
    record.release = m_firstRelease + (cycle - 1) * PeriodNs;
    record.start = start;
    Estimate output;
    if (legacy) {
        Advice candidate;
        if (m_handoff->results.pop(candidate)) {
            m_advice = candidate;
        }
        if (m_advice.session != m_handoff->session.load(std::memory_order_acquire) ||
            start < m_advice.sampledNs || start - m_advice.sampledNs > FreshnessNs) {
            m_advice = {};
        }
        record.advice = m_advice;
        output = estimateSun(snapshot.sensors);
    } else {
        recover(snapshot, record);
        output = m_recovery.estimate(snapshot.sensors, cycle);
    }
    record.submitted = m_receiver->accept(cycle, output);
    record.finish = monotonicNs();
    if (record.submitted) {
        record.output = m_receiver->value();
    }
    if (!legacy) {
        record.sensors = snapshot.sensors;
        const auto truth = truthSun(cycle);
        record.truth = {truth[0], truth[1], truth[2], true};
        if (!m_sensorFaultLogged && cycle >= InjectionCycle &&
            m_scenario != Scenario::Normal && m_scenario != Scenario::Gate && m_scenario != Scenario::Transport) {
            m_sensorFaultLogged = record.sensorFault = true;
        }
    }
    if (!m_handoff->snapshots.push(snapshot)) {
        ++m_snapshotDrops;
    }
    record.snapshotDrops = m_snapshotDrops;
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
