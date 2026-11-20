#include <csignal>
#include <cinttypes>
#include <cstdio>
#include <thread>
#include <unistd.h>

#include "Components/Link/Options.hpp"
#include "Components/Link/Transport.hpp"
#include "MlDeployment/Top/AdvisorTopologyAc.hpp"
#include "Os/Os.hpp"

#ifdef FPRIME_QNX_ML_ADVISOR
#include <exception>
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
    Os::init();
    M2::Options options;
    if (!M2::parseOptions(argc, argv, false, options)) {
        std::fprintf(stderr, "Usage: MlAdvisor [--transport udp|qnx] [--port N] [--m3 SCENARIO] [--model PATH]\n");
        return 2;
    }
#ifdef FPRIME_QNX_ML_ADVISOR
    std::unique_ptr<M4::Ffn> model;
    if (options.model != nullptr) {
        try {
            model = std::make_unique<M4::Ffn>(options.model, M4::Features::AdcsBias);
        } catch (const std::exception& error) {
            std::fprintf(stderr, "MlAdvisor model: %s\n", error.what());
            return 1;
        }
        std::puts("MODEL mlpack=4.7.0 schema=adcs-bias openblas_threads=1");
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
    std::printf("READY pid=%" PRIu64 " transport=%s client=%" PRIu64 "\n",
                pid, M2::transportName(options.transport), client);
    std::fflush(stdout);

    const bool legacy = options.scenario == M2::Scenario::Legacy;
    const M2::Packet request{M2::MessageType::Request, client, 0, legacy ? 0 : pid};
    GateExercise exercise;
    std::uint64_t lastCycle = 0;
    std::uint64_t session = 0;
    bool first = true;
    bool original = false;
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
            if (first) {
                original = snapshot.cycle < M2::InjectionCycle;
                first = false;
                if (options.scenario == M2::Scenario::Crash && !original) {
                    M2::Packet old{M2::MessageType::Result, client, snapshot.session - 1, snapshot.cycle};
                    (void)post(transport, hub, old);
                }
            }
            if (original && snapshot.cycle >= M2::InjectionCycle && options.scenario == M2::Scenario::Crash) {
                event("CRASH_BEGIN", pid, snapshot.session, snapshot.cycle);
                // Abrupt termination without a core file that could skew the paired run.
                kill(getpid(), SIGKILL);
                return 1;
            }
            if (options.scenario == M2::Scenario::Stall && snapshot.cycle >= M2::InjectionCycle &&
                snapshot.cycle < M2::InjectionCycle + 30) {
                event(stalled ? "HEARTBEAT" : "STALL_BEGIN", pid, snapshot.session, snapshot.cycle);
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
                        result.action = prediction.alert ? M2::ExcludeSunSensor : 0;
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
