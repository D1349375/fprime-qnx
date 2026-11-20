#ifndef M4_BIAS_FEATURES_HPP
#define M4_BIAS_FEATURES_HPP

#include "Components/Link/Protocol.hpp"

namespace M4 {

constexpr unsigned BiasFeatureCount = 5;

inline std::array<double, BiasFeatureCount> biasFeatures(const M2::SensorReadings& readings) {
    const double x = readings[0] / 1000.0;
    const double y = readings[1] / 1000.0;
    const double z = readings[2] / 1000.0;
    const double xy = readings[3] / 1000.0;
    // The X and Y projections predict the illuminated XY diagonal in a healthy sample.
    return {{x, y, z, xy, x + y - 1.4142135623730951 * xy}};
}

}  // namespace M4

#endif
