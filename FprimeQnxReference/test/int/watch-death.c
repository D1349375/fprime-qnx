#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/neutrino.h>
#include <sys/procmgr.h>
#include <time.h>

// A separate test process records when the QNX process-manager pulse is received.
int main(void) {
    const int pulse_code = _PULSE_CODE_MINAVAIL;
    const int channel = ChannelCreate(_NTO_CHF_PRIVATE);
    if (channel == -1) {
        perror("ChannelCreate");
        return EXIT_FAILURE;
    }
    const int connection = ConnectAttach(0, 0, channel, _NTO_SIDE_CHANNEL, _NTO_COF_CLOEXEC);
    if (connection == -1) {
        perror("ConnectAttach");
        return EXIT_FAILURE;
    }

    struct sigevent event;
    SIGEV_PULSE_INIT(&event, connection, SIGEV_PULSE_PRIO_INHERIT, pulse_code, 0);
    SIGEV_MAKE_UPDATEABLE(&event);
    if (MsgRegisterEvent(&event, SYSMGR_COID) == -1 ||
        procmgr_event_notify(PROCMGR_EVENT_PROCESS_DEATH, &event) == -1) {
        perror("Register process death notification");
        return EXIT_FAILURE;
    }

    if (puts("ns,pid") == EOF || fflush(stdout) == EOF) {
        return EXIT_FAILURE;
    }
    for (;;) {
        struct _pulse pulse;
        if (MsgReceivePulse(channel, &pulse, sizeof pulse, NULL) == -1) {
            perror("MsgReceivePulse");
            return EXIT_FAILURE;
        }
        if (pulse.code == pulse_code) {
            struct timespec observed;
            if (clock_gettime(CLOCK_MONOTONIC, &observed) == -1) {
                perror("clock_gettime");
                return EXIT_FAILURE;
            }
            const uint64_t time_ns = (uint64_t)observed.tv_sec * UINT64_C(1000000000) + observed.tv_nsec;
            if (printf("%" PRIu64 ",%d\n", time_ns, pulse.value.sival_int) < 0 || fflush(stdout) == EOF) {
                return EXIT_FAILURE;
            }
        }
    }
}
