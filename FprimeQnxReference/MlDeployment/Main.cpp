#include <csignal>
#include <cinttypes>
#include <cstdio>
#include <thread>
#include <unistd.h>

#include "Components/Link/Options.hpp"
#include "Components/Link/Transport.hpp"
#include "MlDeployment/Top/AdvisorTopologyAc.hpp"
#include "Os/Os.hpp"

namespace {

volatile std::sig_atomic_t running = 1;
void stopAdvisor(int) {
    running = 0;
}

bool makeDeterministicAdvice(const M2::SensorReadings& sensors) {
    // A deterministic placeholder for validating the M2 interface.
    return sensors[0] > 750;
}

}  // namespace

int main(int argc, char** argv) {
    Os::init();
    M2::Options options;
    if (!M2::parseOptions(argc, argv, false, options)) {
        std::fprintf(stderr, "Usage: MlAdvisor [--transport udp|qnx] [--port N]\n");
        return 2;
    }
    M2::Transport transport;
    if (!transport.open(options.transport, false, options.port)) {
        std::perror("MlAdvisor transport");
        return 1;
    }
    M2Advisor::initComponents(M2Advisor::TopologyState{});
    M2Advisor::setBaseIds();
    M2Advisor::connectComponents();
    auto& hubLink = M2Advisor::hubLink;
    hubLink.configure();
    std::signal(SIGINT, stopAdvisor);
    std::signal(SIGTERM, stopAdvisor);
    const auto client = M2::monotonicNs();
    std::printf("READY pid=%ld transport=%s client=%" PRIu64 "\n", static_cast<long>(getpid()),
                M2::transportName(options.transport), client);
    std::fflush(stdout);

    std::uint64_t lastCycle = 0;
    std::uint64_t session = 0;
    while (running) {
        const M2::Packet request{M2::MessageType::Request, client};
        M2::HubFrame frame;
        M2::Packet snapshot;
        if (transport.exchange(hubLink.wrap(request), frame) && hubLink.unwrap(frame, snapshot) &&
            snapshot.type == M2::MessageType::Snapshot && snapshot.client == client &&
            (snapshot.session != session || snapshot.cycle > lastCycle)) {
            M2::Packet result{M2::MessageType::Result, client, snapshot.session, snapshot.cycle,
                              makeDeterministicAdvice(snapshot.sensors)};
            M2::Packet ack;
            if (transport.exchange(hubLink.wrap(result), frame) && hubLink.unwrap(frame, ack) &&
                ack.type == M2::MessageType::Ack && ack.client == client &&
                ack.session == result.session && ack.cycle == result.cycle && ack.flag) {
                session = snapshot.session;
                lastCycle = snapshot.cycle;
                std::printf("RESULT session=%" PRIu64 " cycle=%" PRIu64 " alert=%d\n",
                            session, lastCycle, result.flag ? 1 : 0);
                std::fflush(stdout);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    return 0;
}
