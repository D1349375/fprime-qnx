#include <csignal>
#include <cinttypes>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <functional>
#include <pthread.h>
#include <system_error>
#include <thread>
#include <unistd.h>

#include "Components/FlightCycle/FlightCycle.hpp"
#include "Components/Link/Options.hpp"
#include "Components/Link/Transport.hpp"
#include "FlightDeployment/Top/FlightTopologyAc.hpp"
#include "Os/Os.hpp"
#include "Svc/PassiveRateGroup/PassiveRateGroup.hpp"

namespace {

void writeTiming(M2::Handoff& handoff, const std::atomic<bool>& running, FILE* file) {
    const auto write = [file](const M2::CycleRecord& row) {
        std::fprintf(file, "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%d,%" PRIu64
                     ",%" PRIu64 ",%" PRIu64 ",%d,%.6f,%.6f,%.6f\n",
                     row.cycle, row.release, row.start, row.finish, row.output.valid ? 1 : 0, row.snapshotDrops,
                     row.advice.session, row.advice.cycle, row.advice.alert ? 1 : 0,
                     row.output.x, row.output.y, row.output.z);
    };
    M2::CycleRecord row{};
    while (running.load(std::memory_order_acquire)) {
        if (handoff.records.pop(row)) {
            write(row);
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
    while (handoff.records.pop(row)) {
        write(row);
    }
}

struct LinkCounts {
    std::uint64_t accepted = 0;
    std::uint64_t rejected = 0;
    std::uint64_t resultDrops = 0;
};

void runLink(M2::Transport& transport,
             M2::HubLink& hub,
             M2::Handoff& handoff,
             const std::atomic<bool>& running,
             LinkCounts& counts) {
    std::uint64_t client = 0;
    std::uint64_t session = M2::monotonicNs();
    std::uint64_t acceptedCycle = 0;
    M2::Snapshot latest{};
    M2::Snapshot issued{};
    while (running.load(std::memory_order_acquire)) {
        M2::HubFrame frame;
        M2::Packet request;
        if (!transport.receive(frame)) {
            continue;
        }
        if (!hub.unwrap(frame, request)) {
            transport.reject();
            continue;
        }

        M2::Packet response;
        response.client = request.client;
        if (request.type == M2::MessageType::Request) {
            if (client != request.client) {
                client = request.client;
                ++session;
                acceptedCycle = 0;
                issued = {};
                handoff.session.store(session, std::memory_order_release);
            }
            for (unsigned i = 0; i < M2::SnapshotCapacity; ++i) {
                if (!handoff.snapshots.pop(latest)) {
                    break;
                }
            }
            const auto now = M2::monotonicNs();
            response.session = session;
            if (latest.cycle != 0 && now >= latest.sampledNs && now - latest.sampledNs <= M2::FreshnessNs) {
                issued = latest;
                response.type = M2::MessageType::Snapshot;
                response.cycle = issued.cycle;
                response.sensors = issued.sensors;
            }
        } else if (request.type == M2::MessageType::Result) {
            const auto now = M2::monotonicNs();
            response.type = M2::MessageType::Ack;
            response.session = request.session;
            response.cycle = request.cycle;
            const bool matches = request.client == client && request.session == session &&
                                 request.cycle != 0 && request.cycle == issued.cycle &&
                                 request.cycle > acceptedCycle && now - issued.sampledNs <= M2::FreshnessNs;
            if (matches) {
                if (handoff.results.push({session, issued.cycle, issued.sampledNs, request.flag})) {
                    acceptedCycle = issued.cycle;
                    ++counts.accepted;
                    response.flag = true;
                } else {
                    ++counts.resultDrops;
                }
            }
            if (!response.flag) {
                ++counts.rejected;
            }
        }
        transport.send(hub.wrap(response));
    }
}

Svc::QnxTimer* signalTimer = nullptr;
volatile std::sig_atomic_t stopRequested = 0;
void stopFlight(int) {
    stopRequested = 1;
    signalTimer->quit();
}

}  // namespace

int main(int argc, char** argv) {
    Os::init();
    M2::Options options;
    if (!M2::parseOptions(argc, argv, true, options)) {
        std::fprintf(stderr, "Usage: FlightSW [--transport udp|qnx] [--port N] [--cycles N] [--log PATH]\n");
        return 2;
    }

    M2::Transport transport;
    if (!transport.open(options.transport, true, options.port)) {
        std::perror("FlightSW transport");
        return 1;
    }
    FILE* file = std::fopen(options.log, "w");
    if (file == nullptr) {
        std::perror(options.log);
        return 1;
    }
    std::fputs("cycle_id,release_ns,start_ns,finish_ns,valid,snapshot_drops,advisor_session,advisor_cycle,"
               "advisor_alert,sun_x,sun_y,sun_z\n", file);
    std::setvbuf(file, nullptr, _IOLBF, 0);

    M2::Handoff handoff;
    M2Flight::initComponents(M2Flight::TopologyState{});
    M2Flight::setBaseIds();
    M2Flight::connectComponents();
    M2Flight::hubLink.configure();
    M2Flight::rateGroup.configure(Svc::PassiveRateGroup::ContextArray{});
    auto& timer = M2Flight::timer;
    auto& flight = M2Flight::flight;

    signalTimer = &timer;
    std::signal(SIGINT, stopFlight);
    std::signal(SIGTERM, stopFlight);
    std::atomic<bool> running{true};
    LinkCounts counts;
    std::thread worker;
    std::thread logger;
    try {
        worker = std::thread(runLink, std::ref(transport), std::ref(M2Flight::hubLink), std::ref(handoff),
                             std::cref(running), std::ref(counts));
        logger = std::thread(writeTiming, std::ref(handoff), std::cref(running), file);
    } catch (const std::system_error& error) {
        std::fprintf(stderr, "FlightSW worker setup: %s\n", error.what());
        running.store(false, std::memory_order_release);
        if (worker.joinable()) {
            worker.join();
        }
        std::fclose(file);
        return 1;
    }

    sched_param priority{};
    priority.sched_priority = 30;
    const int scheduleStatus = pthread_setschedparam(pthread_self(), SCHED_FIFO, &priority);
    if (scheduleStatus == 0) {
        const auto firstRelease = M2::monotonicNs() + 100000000;
        flight.schedule(handoff, timer, firstRelease, options.cycles);
        std::printf("READY pid=%ld transport=%s period_ns=%" PRIu64 " first_release_ns=%" PRIu64
                    " fifo_priority=%d\n", static_cast<long>(getpid()), M2::transportName(options.transport),
                    M2::PeriodNs, firstRelease, priority.sched_priority);
        std::fflush(stdout);
        timer.startTimerAt(Fw::TimeInterval(0, static_cast<U32>(M2::PeriodNs / 1000)), M2::toTimespec(firstRelease));
    } else {
        std::fprintf(stderr, "FlightSW configure SCHED_FIFO: %s\n", std::strerror(scheduleStatus));
    }
    running.store(false, std::memory_order_release);
    worker.join();
    logger.join();
    const bool logOk = std::ferror(file) == 0 && std::fflush(file) == 0;
    const bool closed = std::fclose(file) == 0;
    std::printf("SUMMARY expected=%" PRIu64 " last_cycle=%" PRIu64 " record_drops=%" PRIu64
                " accepted=%" PRIu64 " rejected=%" PRIu64 " result_drops=%" PRIu64 " timer_overruns=%" PRIu64 "\n",
                options.cycles, flight.lastCycle(), flight.recordDrops(), counts.accepted, counts.rejected,
                counts.resultDrops, static_cast<std::uint64_t>(timer.getOverrunCount()));
    return scheduleStatus == 0 && logOk && closed && (options.cycles == 0 ? stopRequested != 0 : flight.complete())
        ? 0 : 1;
}
