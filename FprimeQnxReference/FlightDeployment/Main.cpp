#include <csignal>
#include <cinttypes>
#include <chrono>
#include <cerrno>
#include <climits>
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

struct LinkEvent {
    std::uint64_t ns;
    const char* event;
    std::uint64_t pid;
    std::uint64_t session;
    std::uint64_t cycle;
    std::uint64_t sample;
};

using LinkTrace = M2::SpscQueue<LinkEvent, 256>;

void writeTiming(M2::Handoff& handoff,
                 LinkTrace& linkTrace,
                 const std::atomic<bool>& logging,
                 FILE* file,
                 FILE* events) {
    const bool m3 = events != nullptr;
    const auto write = [file, m3](const M2::CycleRecord& row) {
        std::fprintf(file, "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%d,%" PRIu64
                     ",%" PRIu64 ",%" PRIu64 ",%d,%.9f,%.9f,%.9f",
                     row.cycle, row.release, row.start, row.finish, row.output.valid ? 1 : 0, row.snapshotDrops,
                     row.advice.session, row.advice.cycle, row.advice.alert ? 1 : 0,
                     row.output.x, row.output.y, row.output.z);
        if (m3) {
            std::fprintf(file, ",%d,%d,%d,%s,%s,%s,%d,%d,%u,%" PRIu64 ",%" PRIu64 ",%" PRIu64
                         ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%u,%u,%.9f,%.9f,%.9f",
                         row.submitted, row.fdir, row.rejoin, row.fallback, row.gate, row.fdirGate,
                         row.isolated, row.sensorFault, row.excluded, row.advice.sampledNs, row.checked.session,
                         row.checked.cycle, row.checked.sampledNs, row.gateNs, row.fallbackNs,
                         static_cast<unsigned>(row.checked.action), static_cast<unsigned>(row.checked.channel),
                         row.truth.x, row.truth.y, row.truth.z);
            for (auto reading : row.sensors) {
                std::fprintf(file, ",%u", static_cast<unsigned>(reading));
            }
            std::fprintf(file, ",%d,%" PRIu64 ",%" PRIu64, row.fdirCandidate, row.fdirGateNs, row.fdirCandidateNs);
        }
        std::fputc('\n', file);
    };
    const auto writeNext = [&handoff, &linkTrace, &write, events]() {
        M2::CycleRecord row{};
        const bool hasCycle = handoff.records.pop(row);
        if (hasCycle) {
            write(row);
        }
        LinkEvent entry{};
        const bool hasEvent = events != nullptr && linkTrace.pop(entry);
        if (hasEvent) {
            std::fprintf(events, "%" PRIu64 ",%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
                         entry.ns, entry.event, entry.pid, entry.session, entry.cycle, entry.sample);
        }
        return hasCycle || hasEvent;
    };
    while (logging.load(std::memory_order_acquire)) {
        if (!writeNext()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
    while (writeNext()) {
    }
}

struct LinkCounts {
    std::uint64_t accepted = 0;
    std::uint64_t rejected = 0;
    std::uint64_t resultDrops = 0;
    std::uint64_t eventDrops = 0;
};

// The injection controller is independent of the IPC and flight threads.
class ReplyPause {
  public:
    void control(const std::atomic<bool>& running) {
        while (running.load(std::memory_order_acquire)) {
            const auto stop = begin.load(std::memory_order_acquire);
            if (stop != 0 && M2::monotonicNs() - stop >= 400000000) {
                release.store(M2::monotonicNs(), std::memory_order_release);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    std::atomic<std::uint64_t> begin{0};
    std::atomic<std::uint64_t> release{0};
};

void runLink(M2::Transport& transport,
             M2::HubLink& hub,
             M2::Handoff& handoff,
             const std::atomic<bool>& running,
             LinkCounts& counts,
             LinkTrace* linkTrace,
             ReplyPause* pause) {
    const bool m3 = linkTrace != nullptr;
    const auto log = [linkTrace, &counts](std::uint64_t now, const char* event, std::uint64_t pid,
                                          std::uint64_t session, std::uint64_t cycle, std::uint64_t sample) {
        if (linkTrace != nullptr && !linkTrace->push({now, event, pid, session, cycle, sample})) {
            ++counts.eventDrops;
        }
    };
    std::uint64_t client = 0;
    std::uint64_t session = M2::monotonicNs();
    std::uint64_t acceptedCycle = 0;
    M2::Snapshot latest{};
    M2::Snapshot issued{};
    // Keep a cycle-addressed sample long enough to distinguish stale from unissued.
    std::array<M2::Snapshot, 32> issuedHistory{};
    std::uint64_t epoch = 0;
    std::uint64_t advisorPid = 0;
    while (running.load(std::memory_order_acquire)) {
        M2::HubFrame frame;
        M2::Packet request;
        const bool received = transport.receive(frame);
        if (advisorPid > 0 && kill(static_cast<pid_t>(advisorPid), 0) == -1 && errno == ESRCH) {
            log(M2::monotonicNs(), "EXIT_OBSERVED", advisorPid, session, 0, 0);
            advisorPid = 0;
        }
        if (!received) {
            continue;
        }
        if (!hub.unwrap(frame, request)) {
            log(M2::monotonicNs(), "R2_FORMAT", 0, 0, 0, 0);
            transport.reject();
            continue;
        }

        M2::Packet response;
        response.client = request.client;
        if (request.type == M2::MessageType::Request) {
            if (m3 && (request.cycle == 0 || request.cycle > INT_MAX ||
                       request.session != 0 || request.flag)) {
                log(M2::monotonicNs(), "R2_FORMAT", 0, 0, 0, 0);
                transport.reject();
                continue;
            }
            const auto flightEpoch = handoff.epoch.load(std::memory_order_acquire);
            if (client != request.client || epoch != flightEpoch) {
                client = request.client;
                epoch = flightEpoch;
                advisorPid = m3 ? request.cycle : 0;
                ++session;
                acceptedCycle = 0;
                issued = {};
                issuedHistory.fill({});
                handoff.session.store(session, std::memory_order_release);
                log(M2::monotonicNs(), "SESSION", advisorPid, session, 0, 0);
            }
            for (unsigned i = 0; i < M2::SnapshotCapacity; ++i) {
                if (!handoff.snapshots.pop(latest)) {
                    break;
                }
            }
            const auto now = M2::monotonicNs();
            if (pause != nullptr && latest.cycle >= M2::InjectionCycle &&
                pause->begin.load(std::memory_order_relaxed) == 0) {
                pause->begin.store(now, std::memory_order_release);
                log(now, "REPLY_HELD", advisorPid, session, latest.cycle, latest.sampledNs);
                bool unblockObserved = false;
                while (running.load(std::memory_order_acquire) &&
                       pause->release.load(std::memory_order_acquire) == 0) {
                    if (unblockObserved) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    } else if (transport.waitForPendingUnblock()) {
                        unblockObserved = true;
                        log(M2::monotonicNs(), "REPLY_UNBLOCK", advisorPid, session, latest.cycle, latest.sampledNs);
                    }
                }
                log(M2::monotonicNs(), "REPLY_RELEASED", advisorPid, session, latest.cycle,
                    pause->release.load(std::memory_order_acquire));
                transport.reject();
                continue;
            }
            response.session = session;
            if (latest.cycle != 0 && now >= latest.sampledNs && now - latest.sampledNs <= M2::FreshnessNs) {
                issued = latest;
                issuedHistory[issued.cycle % issuedHistory.size()] = issued;
                response.type = M2::MessageType::Snapshot;
                response.cycle = issued.cycle;
                response.sensors = issued.sensors;
                log(now, "ISSUED", advisorPid, session, issued.cycle, issued.sampledNs);
            }
        } else if (request.type == M2::MessageType::Result) {
            const auto now = M2::monotonicNs();
            response.type = M2::MessageType::Ack;
            response.session = request.session;
            response.cycle = request.cycle;
            const auto& source = m3 ? issuedHistory[request.cycle % issuedHistory.size()] : issued;
            const char* reason = nullptr;
            if (request.client != client || request.session != session ||
                epoch != handoff.epoch.load(std::memory_order_acquire)) {
                reason = "R2_SESSION";
            } else if (request.cycle == 0 || request.cycle != source.cycle) {
                reason = request.cycle != 0 && request.cycle == acceptedCycle ? "R2_DUPLICATE" : "R2_UNISSUED";
            } else if (now - source.sampledNs > M2::FreshnessNs) {
                reason = "R2_STALE";
            } else if (request.cycle <= acceptedCycle) {
                reason = "R2_DUPLICATE";
            } else if (!m3 && (request.action != 0 || request.channel != 0)) {
                reason = "R2_FORMAT";
            }
            if (reason == nullptr || (m3 && request.client == client)) {
                const M2::Advice advice{request.session, request.cycle,
                                        request.cycle == source.cycle ? source.sampledNs : 0,
                                        request.flag, request.action, request.channel, epoch, reason};
                if (!handoff.results.push(advice)) {
                    ++counts.resultDrops;
                    if (reason == nullptr) {
                        reason = "RESULT_QUEUE_FULL";
                    }
                } else if (reason == nullptr) {
                    acceptedCycle = source.cycle;
                    ++counts.accepted;
                    response.flag = true;
                }
            }
            log(now, reason == nullptr ? "QUEUED" : reason, advisorPid, request.session, request.cycle,
                request.cycle == source.cycle ? source.sampledNs : 0);
            if (!response.flag) {
                ++counts.rejected;
            }
        } else {
            log(M2::monotonicNs(), "R2_FORMAT", 0, 0, 0, 0);
            transport.reject();
            continue;
        }
        const bool sent = transport.send(hub.wrap(response));
        if (m3 && response.type == M2::MessageType::Snapshot) {
            log(M2::monotonicNs(), sent ? "SNAPSHOT_REPLIED" : "SNAPSHOT_REPLY_ERROR",
                advisorPid, session, issued.cycle, issued.sampledNs);
        }
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
    if (!M2::parseOptions(argc, argv, true, options) ||
        (options.scenario == M2::Scenario::Transport && options.transport != M2::TransportKind::Qnx)) {
        std::fprintf(stderr, "Usage: FlightSW [--transport udp|qnx] [--port N] [--cycles N] [--log PATH] [--m3 SCENARIO] [--link-log PATH] [--m4-seed N]\n");
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
    const bool m3 = options.scenario != M2::Scenario::Legacy;
    FILE* events = m3 ? std::fopen(options.linkLog, "w") : nullptr;
    if (m3 && events == nullptr) {
        std::perror(options.linkLog);
        std::fclose(file);
        return 1;
    }
    std::setvbuf(file, nullptr, _IOLBF, 0);
    std::fputs("cycle_id,release_ns,start_ns,finish_ns,valid,snapshot_drops,advisor_session,advisor_cycle,"
               "advisor_alert,sun_x,sun_y,sun_z", file);
    if (m3) {
        std::fputs(",submitted,fdir,rejoin,fallback,gate,fdir_gate,isolated,sensor_fault,excluded,"
                   "advisor_sample_ns,checked_session,checked_cycle,checked_sample_ns,gate_ns,fallback_ns,"
                   "action,channel,truth_x,truth_y,truth_z,s0,s1,s2,s3,s4,s5,fdir_candidate,fdir_gate_ns,fdir_candidate_ns", file);
        std::setvbuf(events, nullptr, _IOLBF, 0);
        std::fputs("ns,event,pid,session,cycle,sample_ns\n", events);
    }
    std::fputc('\n', file);

    M2::Handoff handoff;
    M2::EstimateReceiver receiver;
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
    std::atomic<bool> logging{true};
    LinkTrace linkTrace;
    LinkCounts counts;
    std::thread worker;
    std::thread logger;
    std::thread controller;
    ReplyPause pause;
    const bool holdReply = options.scenario == M2::Scenario::Transport;
    try {
        if (holdReply) {
            controller = std::thread(&ReplyPause::control, &pause, std::cref(running));
        }
        worker = std::thread(runLink, std::ref(transport), std::ref(M2Flight::hubLink), std::ref(handoff),
                             std::cref(running), std::ref(counts), m3 ? &linkTrace : nullptr,
                             holdReply ? &pause : nullptr);
        logger = std::thread(writeTiming, std::ref(handoff), std::ref(linkTrace), std::cref(logging), file, events);
    } catch (const std::system_error& error) {
        std::fprintf(stderr, "FlightSW worker setup: %s\n", error.what());
        running.store(false, std::memory_order_release);
        if (worker.joinable()) {
            worker.join();
        }
        if (controller.joinable()) {
            controller.join();
        }
        if (events != nullptr) {
            std::fclose(events);
        }
        std::fclose(file);
        return 1;
    }

    sched_param priority{};
    priority.sched_priority = 30;
    const int scheduleStatus = pthread_setschedparam(pthread_self(), SCHED_FIFO, &priority);
    if (scheduleStatus == 0) {
        const auto firstRelease = M2::monotonicNs() + 100000000;
        flight.schedule(handoff, timer, receiver, firstRelease, options.cycles, options.scenario, options.replaySeed);
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
    if (controller.joinable()) {
        controller.join();
    }
    logging.store(false, std::memory_order_release);
    logger.join();
    bool eventsOk = true;
    if (events != nullptr) {
        eventsOk = std::fflush(events) == 0 && std::ferror(events) == 0;
        eventsOk = (std::fclose(events) == 0) && eventsOk;
    }
    const bool logOk = std::ferror(file) == 0 && std::fflush(file) == 0;
    const bool closed = std::fclose(file) == 0;
    const bool ok = scheduleStatus == 0 && eventsOk && logOk && closed &&
                    (options.cycles == 0 ? stopRequested != 0 : flight.complete());
    std::printf("SUMMARY expected=%" PRIu64 " last_cycle=%" PRIu64 " record_drops=%" PRIu64
                " accepted=%" PRIu64 " rejected=%" PRIu64 " result_drops=%" PRIu64 " timer_overruns=%" PRIu64,
                options.cycles, flight.lastCycle(), flight.recordDrops(), counts.accepted, counts.rejected,
                counts.resultDrops, static_cast<std::uint64_t>(timer.getOverrunCount()));
    if (m3) {
        std::printf(" link_drops=%" PRIu64, counts.eventDrops);
    }
    std::printf(" exit_ok=%d\n", ok);
    return ok ? 0 : 1;
}
