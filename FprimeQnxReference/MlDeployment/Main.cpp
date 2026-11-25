#include <cerrno>
#include <csignal>
#include <cinttypes>
#include <cstdio>
#include <fcntl.h>
#include <thread>
#include <unistd.h>
#include <limits>
#include <sys/mman.h>
#include <sys/resource.h>

#include "Components/Link/Options.hpp"
#include "Components/Link/Transport.hpp"
#include "MlDeployment/SporadicExercise.hpp"
#include "MlDeployment/Top/AdvisorTopologyAc.hpp"
#include "Os/Os.hpp"

#ifdef FPRIME_QNX_ML_ADVISOR
#include <exception>
#include "Components/FlightCycle/AdcsReplay.hpp"
#include "MlDeployment/BiasFeatures.hpp"
#include "MlDeployment/Ffn.hpp"
#endif

namespace {

volatile std::sig_atomic_t running = 1;
void stopAdvisor(int) {
    running = 0;
}

void event(const char* kind, std::uint64_t pid, std::uint64_t session, std::uint64_t cycle) {
    std::printf("EVENT %s ns=%" PRIu64 " pid=%" PRIu64 " session=%" PRIu64 " cycle=%" PRIu64 "\n",
                kind, M2::monotonicNs(), pid, session, cycle);
    std::fflush(stdout);
}

bool post(M2::Transport& transport, M2::HubLink& hub, const M2::Packet& result) {
    M2::HubFrame frame;
    M2::Packet ack;
    return transport.exchange(hub.wrap(result), frame) && hub.unwrap(frame, ack) &&
           ack.type == M2::MessageType::Ack && ack.client == result.client &&
           ack.session == result.session && ack.cycle == result.cycle && ack.flag;
}

constexpr std::uint64_t BYTES_PER_MIB = 1024 * 1024;

bool capAddressSpace(std::uint64_t limitMiB, std::size_t& bytes) {
    if (limitMiB > std::numeric_limits<std::size_t>::max() / BYTES_PER_MIB ||
        limitMiB > std::numeric_limits<rlim_t>::max() / BYTES_PER_MIB) {
        errno = EOVERFLOW;
        return false;
    }
    bytes = static_cast<std::size_t>(limitMiB * BYTES_PER_MIB);
    const auto requested = static_cast<rlim_t>(bytes);
    rlimit inherited{};
    if (getrlimit(RLIMIT_AS, &inherited) != 0) {
        return false;
    }
    if ((inherited.rlim_cur != RLIM_INFINITY && requested > inherited.rlim_cur) ||
        (inherited.rlim_max != RLIM_INFINITY && requested > inherited.rlim_max)) {
        errno = EINVAL;
        return false;
    }
    const rlimit limit{requested, requested};
    return setrlimit(RLIMIT_AS, &limit) == 0;
}

bool allocationDenied(std::size_t bytes) {
    // Request the whole configured address space while the advisor already has mappings.
    void* const allocation = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (allocation == MAP_FAILED) {
        if (errno == ENOMEM) {
            return true;
        }
        std::perror("MlAdvisor allocation test");
        return false;
    }
    munmap(allocation, bytes);
    std::fputs("MlAdvisor address-space test unexpectedly mapped the full limit\n", stderr);
    return false;
}

class GateExercise {
  public:
    void proposal(M2::Packet& result) {
        if (m_stage == 0 && result.cycle >= M2::InjectionCycle) {
            result.action = M2::ExcludeSunSensor;
            result.channel = 1;
            ++m_stage;
        } else if (result.cycle >= 145 && m_whitelistAttempts < 5) {
            result.action = 255;
            ++m_whitelistAttempts;
        }
    }

    void probes(M2::Transport& transport, M2::HubLink& hub, M2::Packet result) {
        if (m_stage == 1 && result.cycle >= 60) {
            m_saved = result;
        } else if (m_stage == 2 && result.cycle >= 66) {
            --result.session;
        } else if (m_stage == 3 && result.cycle >= 72) {
            result.cycle += 1000;
        } else if (m_stage == 4 && result.cycle >= 78 && result.cycle >= m_saved.cycle + 14) {
            result = m_saved;
        } else if (m_stage == 5 && result.cycle >= 100) {
            result.type = M2::MessageType::Request;
            result.action = M2::ExcludeSunSensor;
        } else {
            return;
        }
        ++m_stage;
        (void)post(transport, hub, result);
    }

  private:
    unsigned m_stage = 0;
    unsigned m_whitelistAttempts = 0;
    M2::Packet m_saved{};
};

}  // namespace

int main(int argc, char** argv) {
    const auto mainEntry = M2::monotonicNs();
    Os::init();
    M2::Options options;
    if (!M2::parseOptions(argc, argv, false, options)) {
        std::fputs("Usage: MlAdvisor [--transport udp|qnx] [--port N] [--m3 SCENARIO] [--model PATH|--drift-model PATH] [--address-space-mib MiB] [--cpu-load sporadic|unbudgeted]\n"
                   "The crash scenario requires a run-specific --crash-marker PATH.\n", stderr);
        return 2;
    }
    std::size_t addressSpace = 0;
    if (options.addressSpaceMiB != 0 && !capAddressSpace(options.addressSpaceMiB, addressSpace)) {
        std::perror("MlAdvisor RLIMIT_AS");
        return 1;
    }
    bool crashArmed = false;
    if (options.crashMarker != nullptr && access(options.crashMarker, F_OK) != 0) {
        if (errno != ENOENT) {
            std::perror("MlAdvisor crash marker");
            return 1;
        }
        crashArmed = true;
    }
    bool probeOldSession = options.crashMarker != nullptr && !crashArmed;
#ifdef FPRIME_QNX_ML_ADVISOR
    std::unique_ptr<M4::Ffn> model;
    if (options.model != nullptr) {
        try {
            const auto features = options.driftModel ? M4::Features::AdcsDrift : M4::Features::AdcsBias;
            model = std::make_unique<M4::Ffn>(options.model, features);
        } catch (const std::exception& error) {
            std::fprintf(stderr, "MlAdvisor model: %s\n", error.what());
            return 1;
        }
        std::printf("MODEL mlpack=4.7.0 schema=%s openblas_threads=1\n",
                    options.driftModel ? "adcs-drift" : "adcs-bias");
    }
#else
    if (options.model != nullptr) {
        std::fputs("MlAdvisor was built without FFN support\n", stderr);
        return 2;
    }
#endif
    M2::Transport transport;
    if (!transport.open(options.transport, false, options.port)) {
        std::perror("MlAdvisor transport");
        return 1;
    }
    M2Advisor::initComponents(M2Advisor::TopologyState{});
    M2Advisor::setBaseIds();
    M2Advisor::connectComponents();
    auto& hub = M2Advisor::hubLink;
    hub.configure();
    std::signal(SIGINT, stopAdvisor);
    std::signal(SIGTERM, stopAdvisor);
    const auto client = M2::monotonicNs();
    const auto pid = static_cast<std::uint64_t>(getpid());
    std::printf("READY pid=%" PRIu64 " transport=%s client=%" PRIu64 " main_entry_ns=%" PRIu64 "\n",
                pid, M2::transportName(options.transport), client, mainEntry);
    std::fflush(stdout);

    const bool legacy = options.scenario == M2::Scenario::Legacy;
    const M2::Packet request{M2::MessageType::Request, client, 0, legacy ? 0 : pid};
    GateExercise exercise;
    std::uint64_t lastCycle = 0;
    std::uint64_t session = 0;
    bool stalled = false;
    while (running) {
        M2::HubFrame frame;
        M2::Packet snapshot;
        if (!transport.exchange(hub.wrap(request), frame)) {
            if (!legacy) {
                event("REQUEST_RETURN_ERROR", pid, session, lastCycle);
            }
        } else if (hub.unwrap(frame, snapshot) && snapshot.type == M2::MessageType::Snapshot &&
                   snapshot.client == client && (snapshot.session != session || snapshot.cycle > lastCycle)) {
            if (probeOldSession) {
                probeOldSession = false;
                M2::Packet old{M2::MessageType::Result, client, snapshot.session - 1, snapshot.cycle};
                (void)post(transport, hub, old);
            }
            if (crashArmed && snapshot.cycle >= M2::InjectionCycle) {
                // SLM's replacement uses the same marker and can only exercise the stale session.
                const int marker = open(options.crashMarker, O_WRONLY | O_CREAT | O_EXCL, 0600);
                if (marker == -1 || close(marker) != 0) {
                    std::perror("MlAdvisor claim crash marker");
                    return 1;
                }
                if (addressSpace != 0) {
                    if (allocationDenied(addressSpace)) {
                        event("ADDRESS_SPACE_DENIED", pid, snapshot.session, snapshot.cycle);
                        event("CRASH_BEGIN", pid, snapshot.session, snapshot.cycle);
                    }
                    return 1;
                }
                event("CRASH_BEGIN", pid, snapshot.session, snapshot.cycle);
                // Abrupt termination without a core file that could skew the paired run.
                kill(getpid(), SIGKILL);
                return 1;
            }
            if (options.scenario == M2::Scenario::Stall && snapshot.cycle >= M2::InjectionCycle &&
                snapshot.cycle < M2::InjectionCycle + 30) {
                event(stalled ? "HEARTBEAT" : "STALL_BEGIN", pid, snapshot.session, snapshot.cycle);
                if (!stalled && options.cpuLoad != M2::CpuLoad::None &&
                    !M2::exerciseScheduling(options.cpuLoad == M2::CpuLoad::Sporadic)) {
                    return 1;
                }
                stalled = true;
                session = snapshot.session;
                lastCycle = snapshot.cycle;
            } else {
                if (stalled) {
                    event("STALL_END", pid, snapshot.session, snapshot.cycle);
                    stalled = false;
                }
                M2::Packet result{M2::MessageType::Result, client, snapshot.session, snapshot.cycle,
                                  legacy && snapshot.sensors[0] > 750};
                double score = -1.0;
#ifdef FPRIME_QNX_ML_ADVISOR
                if (model) {
                    try {
                        const auto features = M4::biasFeatures(snapshot.sensors);
                        const auto prediction = model->predict(features.data(), features.size());
                        score = prediction.score;
                        result.flag = prediction.alert;
                        if (prediction.alert) {
                            // For the drift comparison, warn before proposing an exclusion.
                            // FlightSW independently checks the proposal on its current readings.
                            constexpr auto channel = M4::BiasedChannel;
                            const auto& samples = snapshot.sensors;
                            if (!options.driftModel ||
                                M2::confirmsFault(samples, channel, M2::fitSun(samples, 1U << channel))) {
                                result.action = M2::ExcludeSunSensor;
                                result.channel = channel;
                            }
                        }
                    } catch (const std::exception& error) {
                        // Leave the session without producing a fresh result. SLM may restart the advisor.
                        std::fprintf(stderr, "MlAdvisor inference: %s\n", error.what());
                        return 1;
                    }
                } else
#endif
                if (options.scenario == M2::Scenario::Gate) {
                    exercise.proposal(result);
                } else if (!legacy && snapshot.sensors[0] > 500) {
                    // The fixture's biased X sensor exceeds the deterministic advisor's threshold.
                    // Flight software still needs its independent geometry and residual checks.
                    result.action = M2::ExcludeSunSensor;
                }
                if (post(transport, hub, result)) {
                    session = snapshot.session;
                    lastCycle = snapshot.cycle;
                    std::printf("RESULT session=%" PRIu64 " cycle=%" PRIu64 " alert=%d",
                                session, lastCycle, result.flag ? 1 : 0);
                    if (score >= 0.0) {
                        std::printf(" score=%.17g", score);
                    }
                    std::putchar('\n');
                    std::fflush(stdout);
                    if (options.scenario == M2::Scenario::Gate && result.action == 0) {
                        exercise.probes(transport, hub, result);
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    return 0;
}
