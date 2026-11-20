#ifndef M4_ADCS_REPLAY_HPP
#define M4_ADCS_REPLAY_HPP

#include "Components/FlightCycle/Recovery.hpp"

namespace M4 {

constexpr unsigned BiasedChannel = 0;
constexpr std::uint64_t ReplayCycles = 230;

struct ReplaySample {
    M2::SunVector truth;
    M2::SensorReadings readings;
};

inline std::uint64_t mix(std::uint64_t value) {
    value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
    return value ^ (value >> 31);
}

inline ReplaySample sample(std::uint64_t seed, std::uint64_t cycle, bool bias) {
    const double phase = static_cast<double>((cycle + mix(seed) % 360) % 360) * 0.017453292519943295;
    const double x = 0.46 + 0.0002 * (mix(seed + 1) % 201) + 0.025 * std::sin(phase);
    const double y = 0.20 + 0.0002 * (mix(seed + 2) % 201) + 0.015 * std::cos(phase);
    ReplaySample frame{{x, y, std::sqrt(1.0 - x * x - y * y)}, {}};
    // The three negative axes of the six-axis array are dark on this trajectory.
    // Send the three illuminated axes and the added XY diagonal in M3's slots 0–3.
    for (unsigned channel = 0; channel < 4; ++channel) {
        const int noise = static_cast<int>(mix(seed ^ (8 * cycle + channel)) % 5) - 2;
        const int intensity = static_cast<int>(1000.0 * M2::dot(frame.truth, M2::SensorDirections[channel]) + 0.5);
        frame.readings[channel] = static_cast<std::uint16_t>(intensity + noise);
    }
    if (bias && cycle >= M2::InjectionCycle) {
        frame.readings[BiasedChannel] += static_cast<std::uint16_t>(180 + mix(seed + 3) % 81);
    }
    return frame;
}

}  // namespace M4

#endif
