#include <cstring>
#include <iomanip>
#include <iostream>

#include "Components/FlightCycle/AdcsReplay.hpp"
#include "MlDeployment/BiasFeatures.hpp"

int main(int argc, char** argv) {
    const bool drift = argc == 2 && std::strcmp(argv[1], "drift") == 0;
    if (argc != 1 && !drift) {
        std::cerr << "Usage: " << argv[0] << " [drift]\n";
        return 2;
    }
    struct Split {
        const char* name;
        unsigned first;
        unsigned last;
        bool includeFault;
    };
    const Split biasSplits[] = {{"fit", 1001, 1016, true}, {"validation", 2001, 2004, true},
                                {"test", 3001, 3004, true}};
    const Split driftSplits[] = {{"fit", 1101, 1116, true}, {"validation", 2101, 2116, false},
                                  {"test", 3101, 3104, true}};
    const auto& splits = drift ? driftSplits : biasSplits;
    std::cout << (drift ? "split,seed,drift,cycle,label,fdir_residual,confirmed,truth_x,truth_y,truth_z"
                        : "split,seed,bias,cycle,label,fdir_candidate")
              << ",s0,s1,s2,s3,s4,s5,x,y,z,xy,residual\n"
              << std::setprecision(17);
    for (const auto& split : splits) {
        for (unsigned seed = split.first; seed <= split.last; ++seed) {
            for (const bool fault : {false, true}) {
                if (fault && !split.includeFault) {
                    continue;
                }
                const auto kind = !fault ? M4::SensorFault::None :
                    drift ? M4::SensorFault::Drift : M4::SensorFault::Bias;
                M2::Recovery fdir;
                for (std::uint64_t cycle = 1; cycle <= M4::ReplayCycles; ++cycle) {
                    const auto frame = M4::sample(seed, cycle, kind);
                    std::cout << split.name << ',' << seed << ',' << fault << ',' << cycle << ','
                              << (fault && cycle >= M2::InjectionCycle);
                    if (drift) {
                        constexpr auto channel = M4::BiasedChannel;
                        const auto alternate = M2::fitSun(frame.readings, 1U << channel);
                        std::cout << ',' << M2::sensorResidual(frame.readings, channel, alternate)
                                  << ',' << M2::confirmsFault(frame.readings, channel, alternate);
                        for (const auto axis : frame.truth) {
                            std::cout << ',' << axis;
                        }
                    } else {
                        fdir.observe(frame.readings);
                        std::cout << ',' << fdir.fdirCandidate();
                    }
                    for (const auto reading : frame.readings) {
                        std::cout << ',' << reading;
                    }
                    for (const auto feature : M4::biasFeatures(frame.readings)) {
                        std::cout << ',' << feature;
                    }
                    std::cout << '\n';
                }
            }
        }
    }
    return std::cout ? 0 : 1;
}
