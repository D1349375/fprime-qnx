#ifndef M2_OPTIONS_HPP
#define M2_OPTIONS_HPP

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include "Components/FlightCycle/Recovery.hpp"
#include "Components/Link/Transport.hpp"

namespace M2 {

struct Options {
    TransportKind transport = TransportKind::Udp;
    std::uint16_t port = DefaultPort;
    std::uint64_t cycles = 0;
    const char* log = "flight.csv";
    Scenario scenario = Scenario::Legacy;
    const char* linkLog = "link.csv";
    std::uint64_t replaySeed = 0;
    const char* model = nullptr;
    const char* crashMarker = nullptr;
};

inline bool readUnsigned(const char* text, std::uint64_t& value) {
    if (*text < '0' || *text > '9') {
        return false;
    }
    errno = 0;
    char* end = nullptr;
    value = std::strtoull(text, &end, 10);
    return errno == 0 && *end == '\0';
}

inline bool readScenario(const char* text, Scenario& scenario) {
    const char* const names[] = {"normal", "crash", "stall", "gate", "geometry", "transport", "recovery"};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        if (std::strcmp(text, names[i]) == 0) {
            scenario = static_cast<Scenario>(i + 1);
            return true;
        }
    }
    return false;
}

inline bool parseOptions(int argc, char** argv, bool flight, Options& options) {
    for (int i = 1; i < argc; ++i) {
        const char* key = argv[i];
        if (++i == argc) {
            return false;
        }
        const char* value = argv[i];
        std::uint64_t number = 0;
        if (std::strcmp(key, "--port") == 0 && readUnsigned(value, number) && number > 0 && number <= 65535) {
            options.port = static_cast<std::uint16_t>(number);
        } else if (std::strcmp(key, "--transport") == 0 && std::strcmp(value, "udp") == 0) {
            options.transport = TransportKind::Udp;
        } else if (std::strcmp(key, "--transport") == 0 && std::strcmp(value, "qnx") == 0) {
            options.transport = TransportKind::Qnx;
        } else if (std::strcmp(key, "--m3") == 0 && readScenario(value, options.scenario)) {
        } else if (flight && std::strcmp(key, "--m4-seed") == 0 && readUnsigned(value, number) && number != 0) {
            options.replaySeed = number;
        } else if (!flight && std::strcmp(key, "--model") == 0 && *value != '\0') {
            options.model = value;
        } else if (!flight && std::strcmp(key, "--crash-marker") == 0 && *value != '\0') {
            options.crashMarker = value;
        } else if (flight && std::strcmp(key, "--link-log") == 0 && *value != '\0') {
            options.linkLog = value;
        } else if (flight && std::strcmp(key, "--cycles") == 0 && readUnsigned(value, number)) {
            options.cycles = number;
        } else if (flight && std::strcmp(key, "--log") == 0 && *value != '\0') {
            options.log = value;
        } else {
            return false;
        }
    }
    if (!flight && ((options.scenario == Scenario::Crash) != (options.crashMarker != nullptr))) {
        return false;
    }
    return (options.replaySeed == 0 && options.model == nullptr) || options.scenario == Scenario::Normal ||
           options.scenario == Scenario::Recovery || options.scenario == Scenario::Crash;
}

}  // namespace M2

#endif
