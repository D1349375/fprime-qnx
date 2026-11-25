#include "Components/FlightGround/FlightGround.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>

#include "Components/FlightCycle/FlightCycle.hpp"
#include "Fw/Log/LogString.hpp"

namespace M2 {
namespace {

struct RuleExplanation {
    const char* code;
    const char* reason;
};

const char* gateReason(const char* code) {
    constexpr RuleExplanation explanations[] = {
        {"APPROVED", "Independent checks permit the sensor exclusion"},
        {"R1_WHITELIST", "The proposed action or channel is outside the allowlist"},
        {"R3_PERSISTENCE", "The proposal needs more consecutive confirmations"},
        {"R4_RATE", "The action has reached its rate limit"},
        {"R5_GEOMETRY", "The remaining sensors cannot support a valid estimate"},
        {"R6_CONSISTENCY", "Independent sensor checks did not confirm the fault"},
        {"R8_ISOLATED", "The advisor is temporarily isolated"},
    };
    const auto match = std::find_if(std::begin(explanations), std::end(explanations),
                                    [code](const RuleExplanation& explanation) {
                                        return std::strcmp(explanation.code, code) == 0;
                                    });
    return match == std::end(explanations) ? nullptr : match->reason;
}

const char* linkReason(const char* code) {
    constexpr RuleExplanation explanations[] = {
        {"R2_DUPLICATE", "This snapshot already has a result"},
        {"R2_FORMAT", "The message does not match the advisor protocol"},
        {"R2_SESSION", "The result belongs to an inactive advisor session"},
        {"R2_STALE", "The result has expired"},
        {"R2_UNISSUED", "FlightSW did not issue this snapshot for the session"},
    };
    for (const auto& explanation : explanations) {
        if (std::strcmp(explanation.code, code) == 0) {
            return explanation.reason;
        }
    }
    return "The result failed advisor protocol validation";
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

    if (std::strcmp(m_lastGate, row.gate) != 0) {
        const auto* reason = gateReason(row.gate);
        if (reason != nullptr) {
            const char* verdict = std::strcmp(row.gate, "APPROVED") == 0 ? "APPROVED" : "REJECTED";
            log_ACTIVITY_LO_GateDecision(Fw::LogStringArg(row.gate), Fw::LogStringArg(verdict),
                                         Fw::LogStringArg(reason));
            m_lastGate = row.gate;
        }
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
        log_WARNING_LO_AdviceRejected(Fw::LogStringArg(event), Fw::LogStringArg(linkReason(event)));
        m_lastRejection = event;
    }
}

}  // namespace M2
