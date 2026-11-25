#include "Components/FlightCycle/Recovery.hpp"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <limits>

int main() {
    using namespace M2;
    const auto clean = recoverySensors(Scenario::Normal, InjectionCycle);
    const auto failed = recoverySensors(Scenario::Recovery, InjectionCycle);
    const auto blocked = recoverySensors(Scenario::Geometry, InjectionCycle);
    constexpr std::uint64_t now = NanosecondsPerSecond;
    Recovery gate;
    assert(std::strcmp(gate.evaluate(clean, 255, 0, false, now), "R1_WHITELIST") == 0);
    assert(std::strcmp(gate.evaluate(clean, ExcludeSunSensor, 0, false, now), "R6_CONSISTENCY") == 0);
    assert(std::strcmp(gate.evaluate(blocked, ExcludeSunSensor, 0, false, now), "R5_GEOMETRY") == 0);
    assert(!gate.estimate(blocked, InjectionCycle).valid);
    assert(!gate.estimate(clean, InjectionCycle + MinimumDegradedCycles - 1).valid);
    assert(gate.estimate(clean, InjectionCycle + MinimumDegradedCycles).valid);
    for (unsigned i = 1; i < ResultPersistence; ++i) {
        assert(std::strcmp(gate.evaluate(failed, ExcludeSunSensor, 0, false, now), "R3_PERSISTENCE") == 0);
    }
    assert(std::strcmp(gate.evaluate(failed, ExcludeSunSensor, 0, false, now), "APPROVED") == 0);
    assert(gate.excludedMask() == 1);
    auto second = clean;
    second[1] += 240;
    assert(std::strcmp(gate.evaluate(second, ExcludeSunSensor, 1, true, now + 1), "R4_RATE") == 0);
    assert(gate.excludedMask() == 1);
    assert(std::strcmp(gate.evaluate(second, ExcludeSunSensor, 1, true, now + RejectionWindowNs), "APPROVED") == 0);

    Recovery fdir;
    for (unsigned i = 1; i < FdirPersistence; ++i) {
        fdir.observe(failed);
        assert(fdir.fdirCandidate() == NoChannel);
    }
    fdir.observe(failed);
    assert(fdir.fdirCandidate() == 0);
    assert(std::strcmp(fdir.evaluate(failed, ExcludeSunSensor, 0, true, now), "APPROVED") == 0);
    const auto estimate = fdir.estimate(failed, InjectionCycle);
    const auto reference = truthSun(InjectionCycle);
    assert(estimate.valid && dot({estimate.x, estimate.y, estimate.z}, reference) > 0.999999);

    // A drift warning withholds the fused estimate until the warned channel is excluded.
    Recovery drift;
    auto ramp = clean;
    ramp[0] += 20;
    assert(drift.estimate(ramp, 1).valid);
    assert(drift.observeChannel(ramp, 0, 0.01));
    assert(drift.fdirCandidate() == NoChannel);
    assert(!drift.estimate(ramp, 2).valid);
    assert(!drift.observeChannel(clean, 0, 0.01));
    assert(!drift.estimate(clean, 2 + MinimumDegradedCycles - 1).valid);
    assert(drift.estimate(clean, 2 + MinimumDegradedCycles).valid);
    for (unsigned i = 0; i < FdirPersistence; ++i) {
        assert(drift.observeChannel(failed, 0, 0.01));
    }
    assert(drift.fdirCandidate() == 0);
    assert(std::strcmp(drift.evaluate(failed, ExcludeSunSensor, 0, true, now), "APPROVED") == 0);
    assert(drift.observeChannel(failed, 0, 0.01));
    assert(drift.estimate(failed, 100).valid);

    EstimateReceiver receiver;
    assert(receiver.accept(1, estimate));
    assert(!receiver.accept(1, {}));
    assert(!receiver.accept(2, {std::numeric_limits<double>::quiet_NaN(), 0, 0, true}));
    assert(receiver.accept(2, {}) && !receiver.value().valid);

    Packet result{MessageType::Result, 1, 2, 3};
    result.action = 255;
    result.channel = 5;
    auto wire = encode(result);
    Packet decoded;
    assert(decode(wire, decoded) && decoded.action == 255 && decoded.channel == 5);
    wire[7] = 1;
    assert(!decode(wire, decoded));
    std::puts("PASS deterministic recovery policy and result wire format");
}
