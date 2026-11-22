#define _QNX_SOURCE 1
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/neutrino.h>
#include <sys/syspage.h>
#include <sys/trace.h>
#include <sys/types.h>
#include <time.h>

static int anchor(FILE* output)
{
    struct timespec monotonic;
    const uint64_t before = ClockCycles();
    if (clock_gettime(CLOCK_MONOTONIC, &monotonic) == -1) {
        perror("clock_gettime");
        return 1;
    }
    const uint64_t after = ClockCycles();
    const uint64_t ns = (uint64_t)monotonic.tv_sec * UINT64_C(1000000000) + (uint64_t)monotonic.tv_nsec;
    fprintf(output, "monotonic_ns=%" PRIu64 " cycles_before=%" PRIu64 " cycles_after=%" PRIu64
           " cycles_per_second=%" PRIu64 "\n",
           ns, before, after, (uint64_t)SYSPAGE_ENTRY(qtime)->cycles_per_sec);
    return 0;
}

static int stop(void)
{
    if (TraceEvent(_NTO_TRACE_STOP) == -1) {
        perror("TraceEvent(_NTO_TRACE_STOP)");
        return 1;
    }
    return 0;
}

/* The logger writes complete lines to shared memory, independently of this reader. */
static int updates(FILE* source, const char* prefix)
{
    char line[2048];
    for (;;) {
        const off_t position = ftello(source);
        if (position == -1) {
            return 1;
        }
        if (fgets(line, sizeof(line), source) == NULL) {
            const int error = ferror(source);
            clearerr(source);
            return error;
        }
        if (strchr(line, '\n') == NULL) {
            return strlen(line) == sizeof(line) - 1 || fseeko(source, position, SEEK_SET) != 0;
        }
        printf("%s %s", prefix, line);
    }
}

static int freeze(void)
{
    if (stop() != 0) {
        return 1;
    }
    FILE* trigger = fopen("trace-trigger.txt", "w");
    if (trigger == NULL) {
        perror("trace-trigger.txt");
        return 1;
    }
    const int rc = anchor(trigger);
    return fclose(trigger) != 0 || rc != 0;
}

static int stream(void)
{
    FILE* log = fopen("flight.log", "r");
    FILE* csv = fopen("flight.csv", "r");
    if (log == NULL || csv == NULL) {
        perror("flight log");
        return 1;
    }
    char command[16];
    int rc = 0;
    while (fgets(command, sizeof(command), stdin) != NULL) {
        if (strcmp(command, "sample\n") == 0) {
            fputs("CLOCK ", stdout);
            if (anchor(stdout) != 0 || updates(log, "LOG") != 0 || updates(csv, "ROW") != 0) {
                rc = 1;
                break;
            }
            FILE* status = fopen("trace-scenario-status.txt", "r");
            if (status != NULL) {
                if (fgets(command, sizeof(command), status) != NULL && strchr(command, '\n') != NULL) {
                    printf("DONE %s", command);
                }
                fclose(status);
            }
        } else if (strcmp(command, "freeze\n") == 0) {
            puts(freeze() == 0 ? "FROZEN" : "FREEZE_FAILED");
        } else {
            rc = 2;
            break;
        }
        puts("END");
        if (fflush(stdout) != 0) {
            rc = 1;
            break;
        }
    }
    fclose(csv);
    fclose(log);
    return rc || ferror(stdin);
}

int main(int argc, char** argv)
{
    if (argc == 2 && strcmp(argv[1], "anchor") == 0) {
        return anchor(stdout);
    }
    if (argc == 2 && strcmp(argv[1], "stop") == 0) {
        return stop();
    }
    if (argc == 2 && strcmp(argv[1], "stream") == 0) {
        return stream();
    }
    fputs("Usage: trace-control anchor|stop|stream\n", stderr);
    return 2;
}
