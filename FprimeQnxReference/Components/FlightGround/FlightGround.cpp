#include "Components/FlightGround/FlightGround.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>

#include "Components/FlightCycle/FlightCycle.hpp"
#include "Fw/Log/LogString.hpp"

namespace M2 {
namespace {

bool isGateDecision(const char* gate) {
    constexpr const char* rules[] = {
        "APPROVED", "R1_WHITELIST", "R3_PERSISTENCE", "R4_RATE", "R5_GEOMETRY", "R6_CONSISTENCY", "R8_ISOLATED",
    };
    return std::any_of(std::begin(rules), std::end(rules),
                       [gate](const char* rule) { return std::strcmp(rule, gate) == 0; });
}

}  // namespace

FlightGround::FlightGround(const char* name) : FlightGroundComponentBase(name) {}

void FlightGround::transportReady_handler(FwIndexType) {
    transportReadyOut_out(0);
    m_publishSnapshot.store(true, std::memory_order_release);
}

void FlightGround::observe(const CycleRecord& row) {
    const bool publishSnapshot = m_publishSnapshot.exchange(false, std::memory_order_acq_rel);
    const bool sourceChanged = !m_sourcePublished || m_fdir != row.fdir;
    if (sourceChanged && row.fdir && !m_fdir) {
        log_WARNING_HI_FdirEngaged(Fw::LogStringArg(row.fallback));
    } else if (sourceChanged && !row.fdir && row.rejoin) {
        log_ACTIVITY_HI_AdvisorAccepted(row.checked.session);
    }

    // A new GDS client needs the current status even when control hasn't changed.
    if (sourceChanged || publishSnapshot) {
        tlmWrite_ControlSource(row.fdir ? ControlSource::FDIR : ControlSource::ML);
    }
    const auto session = row.fdir ? m_session : row.advice.session;
    if (session != m_session || publishSnapshot) {
        tlmWrite_AdvisorSession(session);
    }
    m_sourcePublished = true;
    m_fdir = row.fdir;
    m_session = session;

    if (std::strcmp(m_lastGate, row.gate) != 0 && isGateDecision(row.gate)) {
        const char* verdict = std::strcmp(row.gate, "APPROVED") == 0 ? "APPROVED" : "REJECTED";
        log_ACTIVITY_LO_GateDecision(Fw::LogStringArg(row.gate), Fw::LogStringArg(verdict));
        m_lastGate = row.gate;
    }

    if (row.output.valid && row.truth.valid) {
        // These unit vectors are for display only. Gate uses sensor consistency checks.
        const auto dot = row.output.x * row.truth.x + row.output.y * row.truth.y + row.output.z * row.truth.z;
        constexpr double degreesPerRadian = 57.29577951308232;
        tlmWrite_AttitudeErrorDeg(static_cast<F32>(std::acos(std::max(-1.0, std::min(dot, 1.0))) * degreesPerRadian));
    }
}

void FlightGround::observeLink(const char* event) {
    if (std::strcmp(event, "SESSION") == 0) {
        m_lastRejection = "";
        log_WARNING_LO_AdviceRejected_ThrottleClear();
    } else if (std::strncmp(event, "R2_", 3) == 0 && std::strcmp(event, m_lastRejection) != 0) {
        log_WARNING_LO_AdviceRejected(Fw::LogStringArg(event));
        m_lastRejection = event;
    }
}

}  // namespace M2
