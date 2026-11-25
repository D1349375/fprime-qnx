#include "MlDeployment/SporadicExercise.hpp"
#include "Components/Link/Protocol.hpp"

#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <sched.h>
#include <sys/neutrino.h>

namespace M2 {

bool exerciseScheduling(bool sporadic) {
    constexpr int HIGH_PRIORITY = 35;
    constexpr int LOW_PRIORITY = 10;
    constexpr std::uint64_t BUSY_NS = 280000000;
    unsigned runmask = 0;
    if (ThreadCtl(_NTO_TCTL_RUNMASK_GET_AND_SET, &runmask) != 0 || runmask != 1 || SchedGetCpuNum() != 0) {
        std::fputs("Q3 requires MlAdvisor to be pinned to CPU 0\n", stderr);
        return false;
    }
    const auto thread = pthread_self();
    sched_param previous{};
    int previousPolicy = 0;
    int status = pthread_getschedparam(thread, &previousPolicy, &previous);
    if (status != 0) {
        std::fprintf(stderr, "Q3 read original scheduling parameters: %s\n", std::strerror(status));
        return false;
    }

    const int policy = sporadic ? SCHED_SPORADIC : SCHED_FIFO;
    sched_param configured{};
    configured.sched_priority = HIGH_PRIORITY;
    if (sporadic) {
        configured.sched_ss_low_priority = LOW_PRIORITY;
        configured.sched_ss_init_budget = toTimespec(3000000);
        configured.sched_ss_repl_period = toTimespec(40000000);
        configured.sched_ss_max_repl = 4;
    }
    status = pthread_setschedparam(thread, policy, &configured);
    if (status != 0) {
        std::fprintf(stderr, "Q3 set scheduling policy: %s\n", std::strerror(status));
        return false;
    }

    std::uint64_t cpuStart = 0;
    std::uint64_t cpuEnd = 0;
    bool valid = ClockTime(CLOCK_THREAD_CPUTIME_ID, nullptr, &cpuStart) == 0;
    bool highSeen = false;
    bool lowSeen = false;
    const auto end = monotonicNs() + BUSY_NS;
    while (valid && monotonicNs() < end) {
        sched_param observed{};
        int observedPolicy = 0;
        status = pthread_getschedparam(thread, &observedPolicy, &observed);
        valid = status == 0 && observedPolicy == policy && SchedGetCpuNum() == 0;
        highSeen = highSeen || observed.sched_curpriority == HIGH_PRIORITY;
        lowSeen = lowSeen || observed.sched_curpriority == LOW_PRIORITY;
    }
    const bool measured = ClockTime(CLOCK_THREAD_CPUTIME_ID, nullptr, &cpuEnd) == 0 && cpuEnd > cpuStart;
    status = pthread_setschedparam(thread, previousPolicy, &previous);
    if (status != 0) {
        std::fprintf(stderr, "Q3 restore scheduling policy: %s\n", std::strerror(status));
        return false;
    }
    std::printf("Q3_SCHEDULER mode=%s cpu0=%d high=%d low=%d cpu_time_ns=%" PRIu64 "\n",
                sporadic ? "sporadic" : "unbudgeted", valid, highSeen, lowSeen,
                measured ? cpuEnd - cpuStart : 0);
    std::fflush(stdout);
    return valid && measured && highSeen && lowSeen == sporadic;
}

}  // namespace M2
