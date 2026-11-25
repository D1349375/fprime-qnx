#ifndef ADCS_RECOVERY_HPP
#define ADCS_RECOVERY_HPP

#include <algorithm>
#include <array>
#include <cmath>
#include "Components/Link/Protocol.hpp"

namespace M2 {

enum class Scenario { Legacy, Normal, Crash, Stall, Gate, Geometry, Transport, Recovery, Drift };
constexpr std::uint64_t InjectionCycle = 55;
constexpr std::uint64_t RejectionWindowNs = 1000000000;
constexpr std::uint64_t IsolationNs = 1200000000;
constexpr unsigned ResultPersistence = 3;
constexpr unsigned FdirPersistence = 3;
constexpr unsigned RejectionLimit = 4;
constexpr unsigned MinimumDegradedCycles = 10;
constexpr int NoChannel = -1;
constexpr std::uint8_t ExcludeSunSensor = 1;

struct Estimate {
    double x = 0;
    double y = 0;
    double z = 0;
    bool valid = false;
};

// The downstream consumer runs synchronously with FlightCycle. Its single slot
// is owned by the flight thread, which completes consumption before the next tick.
class EstimateReceiver {
  public:
    bool accept(std::uint64_t cycle, const Estimate& value) {
        if (cycle <= m_cycle || (value.valid &&
            !(std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z)))) {
            return false;
        }
        m_cycle = cycle;
        m_value = value;
        return true;
    }

    Estimate value() const { return m_value; }

  private:
    std::uint64_t m_cycle = 0;
    Estimate m_value{};
};

using SunVector = std::array<double, 3>;
constexpr double Diagonal = 0.7071067811865475;
constexpr SunVector SensorDirections[] = {
    {1, 0, 0}, {0, 1, 0}, {0, 0, 1},
    {Diagonal, Diagonal, 0}, {0, Diagonal, Diagonal}, {Diagonal, 0, Diagonal}
};

inline double dot(const SunVector& a, const SunVector& b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

inline SunVector truthSun(std::uint64_t cycle) {
    // Seed-free replay along a bounded trajectory in the positive octant.
    const double x = 0.30 + 0.04 * std::sin(static_cast<double>(cycle % 360) * 0.017453292519943295);
    const double y = 0.48;
    return {x, y, std::sqrt(1 - x * x - y * y)};
}

inline SensorReadings recoverySensors(Scenario scenario, std::uint64_t cycle) {
    const auto sun = truthSun(cycle);
    SensorReadings samples{};
    for (unsigned i = 0; i < samples.size(); ++i) {
        samples[i] = static_cast<std::uint16_t>(1000 * dot(sun, SensorDirections[i]) + 0.5);
    }
    if (cycle >= InjectionCycle && (scenario == Scenario::Recovery || scenario == Scenario::Crash ||
                                   scenario == Scenario::Stall || scenario == Scenario::Geometry)) {
        samples[0] += 240;
    }
    if (cycle >= InjectionCycle && scenario == Scenario::Geometry) {
        samples[3] = samples[4] = samples[5] = 0;
    }
    return samples;
}

struct Fit {
    SunVector vector{};
    double worstResidual = 0;
    bool geometry = false;
};

// Least-squares fit of the illuminated sensors, with a bound on the normal
// matrix condition number. Zero marks a missing or unilluminated sample.
inline Fit fitSun(const SensorReadings& samples, unsigned excludedMask) {
    double augmented[3][7]{};
    for (unsigned i = 0; i < samples.size(); ++i) {
        if ((excludedMask & (1U << i)) != 0 || samples[i] == 0) {
            continue;
        }
        const auto& direction = SensorDirections[i];
        for (unsigned row = 0; row < 3; ++row) {
            for (unsigned column = 0; column < 3; ++column) {
                augmented[row][column] += direction[row] * direction[column];
            }
            augmented[row][6] += direction[row] * samples[i] / 1000.0;
        }
    }
    const auto rowNorm = [&augmented](unsigned offset) {
        double norm = 0;
        for (const auto& row : augmented) {
            norm = std::max(norm, std::abs(row[offset]) + std::abs(row[offset + 1]) + std::abs(row[offset + 2]));
        }
        return norm;
    };
    const double norm = rowNorm(0);
    for (unsigned row = 0; row < 3; ++row) {
        augmented[row][3 + row] = 1;
    }
    for (unsigned pivot = 0; pivot < 3; ++pivot) {
        unsigned selected = pivot;
        for (unsigned row = pivot + 1; row < 3; ++row) {
            if (std::abs(augmented[row][pivot]) > std::abs(augmented[selected][pivot])) {
                selected = row;
            }
        }
        std::swap(augmented[pivot], augmented[selected]);
        const double divisor = augmented[pivot][pivot];
        if (std::abs(divisor) < 1e-6) {
            return {};
        }
        for (auto& value : augmented[pivot]) {
            value /= divisor;
        }
        for (unsigned row = 0; row < 3; ++row) {
            if (row == pivot) {
                continue;
            }
            const double multiplier = augmented[row][pivot];
            for (unsigned column = 0; column < 7; ++column) {
                augmented[row][column] -= multiplier * augmented[pivot][column];
            }
        }
    }
    Fit fit;
    fit.geometry = norm * rowNorm(3) <= 12;
    fit.vector = {augmented[0][6], augmented[1][6], augmented[2][6]};
    for (unsigned i = 0; i < samples.size(); ++i) {
        if ((excludedMask & (1U << i)) == 0 && samples[i] != 0) {
            fit.worstResidual = std::max(fit.worstResidual,
                std::abs(samples[i] / 1000.0 - dot(fit.vector, SensorDirections[i])));
        }
    }
    return fit;
}

inline bool consistent(const Fit& fit) {
    return fit.geometry && fit.worstResidual <= 0.025 &&
           std::abs(std::sqrt(dot(fit.vector, fit.vector)) - 1.0) <= 0.05;
}

inline double sensorResidual(const SensorReadings& samples, unsigned channel, const Fit& alternate) {
    return std::abs(samples[channel] / 1000.0 - dot(alternate.vector, SensorDirections[channel]));
}

inline bool confirmsFault(const SensorReadings& samples, unsigned channel, const Fit& alternate) {
    return consistent(alternate) && samples[channel] != 0 && sensorResidual(samples, channel, alternate) >= 0.12;
}

class Recovery {
  public:
    void observe(const SensorReadings& samples) {
        int candidate = NoChannel;
        for (unsigned channel = 0; channel < samples.size(); ++channel) {
            const unsigned mask = 1U << channel;
            if ((m_excluded & mask) == 0 && confirmsFault(samples, channel, fitSun(samples, m_excluded | mask))) {
                if (candidate != NoChannel) {
                    candidate = NoChannel;
                    break;
                }
                candidate = static_cast<int>(channel);
            }
        }
        updatePersistence(candidate, m_fdirCandidate, m_fdirCount);
    }

    bool observeChannel(const SensorReadings& samples, unsigned channel, double alertCutoff) {
        const unsigned mask = 1U << channel;
        const auto alternate = fitSun(samples, mask);
        const bool alert = sensorResidual(samples, channel, alternate) >= alertCutoff;
        // A calibrated warning can precede the independent evidence needed for a proposal.
        const bool propose = alert && !(m_excluded & mask) && confirmsFault(samples, channel, alternate);
        updatePersistence(propose ? static_cast<int>(channel) : NoChannel, m_fdirCandidate, m_fdirCount);
        // Until the channel is excluded, a warned reading can bias the fused fit while it still
        // passes the consistency bound. Withhold the estimate instead of committing it.
        m_suspected = alert ? (m_suspected | mask) : (m_suspected & ~mask);
        return alert;
    }

    int fdirCandidate() const {
        return m_fdirCount >= FdirPersistence ? m_fdirCandidate : NoChannel;
    }

    void resetProposal() { m_proposed = NoChannel; m_proposalCount = 0; }

    const char* evaluate(const SensorReadings& samples, std::uint8_t action, unsigned channel,
                         bool fdir, std::uint64_t now) {
        if (action == 0) {
            if (channel != 0) {
                resetProposal();
                return "R1_WHITELIST";
            }
            resetProposal();
            return "NO_ACTION";
        }
        if (action != ExcludeSunSensor || channel >= samples.size()) {
            resetProposal();
            return "R1_WHITELIST";
        }
        const unsigned mask = 1U << channel;
        if ((m_excluded & mask) != 0) {
            resetProposal();
            return "ALREADY_EXCLUDED";
        }
        const auto alternate = fitSun(samples, m_excluded | mask);
        if (!alternate.geometry) {
            resetProposal();
            return "R5_GEOMETRY";
        }
        if (!confirmsFault(samples, channel, alternate)) {
            resetProposal();
            return "R6_CONSISTENCY";
        }
        if (!fdir) {
            updatePersistence(static_cast<int>(channel), m_proposed, m_proposalCount);
            if (m_proposalCount < ResultPersistence) {
                return "R3_PERSISTENCE";
            }
        }
        if (m_lastAction != 0 && now - m_lastAction < RejectionWindowNs) {
            return "R4_RATE";
        }
        m_excluded |= mask;
        m_lastAction = now;
        resetProposal();
        return "APPROVED";
    }

    Estimate estimate(const SensorReadings& samples, std::uint64_t cycle) {
        const auto fit = fitSun(samples, m_excluded);
        if (!consistent(fit) || (m_suspected & ~m_excluded) != 0) {
            m_degradedThrough = cycle + MinimumDegradedCycles - 1;
        }
        if (cycle <= m_degradedThrough) {
            return {};
        }
        const double norm = std::sqrt(dot(fit.vector, fit.vector));
        return {fit.vector[0] / norm, fit.vector[1] / norm, fit.vector[2] / norm, true};
    }

    unsigned excludedMask() const { return m_excluded; }

  private:
    static void updatePersistence(int candidate, int& previous, unsigned& count) {
        if (candidate != previous) {
            count = 0;
            previous = candidate;
        }
        if (candidate != NoChannel && count < ResultPersistence) {
            ++count;
        }
    }

    unsigned m_excluded = 0;
    unsigned m_suspected = 0;
    int m_fdirCandidate = NoChannel;
    unsigned m_fdirCount = 0;
    int m_proposed = NoChannel;
    unsigned m_proposalCount = 0;
    std::uint64_t m_lastAction = 0;
    std::uint64_t m_degradedThrough = 0;
};

}  // namespace M2

#endif
