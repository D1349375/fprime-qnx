#include <iostream>
#include <iomanip>

#include "Components/FlightCycle/AdcsReplay.hpp"
#include "MlDeployment/BiasFeatures.hpp"

int main(int argc, char** argv) {
    if (argc != 1) {
        std::cerr << "Usage: " << argv[0] << '\n';
        return 2;
    }
    struct Split {
        const char* name;
        unsigned first;
        unsigned last;
    };
    const Split splits[] = {{"fit", 1001, 1016}, {"validation", 2001, 2004}, {"test", 3001, 3004}};
    std::cout << "split,seed,bias,cycle,label,fdir_candidate,s0,s1,s2,s3,s4,s5,x,y,z,xy,residual\n"
              << std::setprecision(17);
    for (const auto& split : splits) {
        for (unsigned seed = split.first; seed <= split.last; ++seed) {
            for (const bool bias : {false, true}) {
                M2::Recovery fdir;
                for (std::uint64_t cycle = 1; cycle <= M4::ReplayCycles; ++cycle) {
                    const auto frame = M4::sample(seed, cycle, bias);
                    fdir.observe(frame.readings);
                    std::cout << split.name << ',' << seed << ',' << bias << ',' << cycle << ','
                              << (bias && cycle >= M2::InjectionCycle) << ',' << fdir.fdirCandidate();
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
