#define _QNX_SOURCE 1
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/neutrino.h>
#include <sys/syspage.h>
#include <sys/trace.h>
#include <time.h>

static int anchor(void)
{
    struct timespec monotonic;
    const uint64_t before = ClockCycles();
    if (clock_gettime(CLOCK_MONOTONIC, &monotonic) == -1) {
        perror("clock_gettime");
        return 1;
    }
    const uint64_t after = ClockCycles();
    const uint64_t ns = (uint64_t)monotonic.tv_sec * UINT64_C(1000000000) + (uint64_t)monotonic.tv_nsec;
    printf("monotonic_ns=%" PRIu64 " cycles_before=%" PRIu64 " cycles_after=%" PRIu64
           " cycles_per_second=%" PRIu64 "\n",
           ns, before, after, (uint64_t)SYSPAGE_ENTRY(qtime)->cycles_per_sec);
    return 0;
}

int main(int argc, char** argv)
{
    if (argc == 2 && strcmp(argv[1], "anchor") == 0) {
        return anchor();
    }
    if (argc == 2 && strcmp(argv[1], "stop") == 0) {
        if (TraceEvent(_NTO_TRACE_STOP) == -1) {
            perror("TraceEvent(_NTO_TRACE_STOP)");
            return 1;
        }
        return 0;
    }
    fputs("Usage: trace-control anchor|stop\n", stderr);
    return 2;
}
