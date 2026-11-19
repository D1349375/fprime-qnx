#ifndef M2_OPTIONS_HPP
#define M2_OPTIONS_HPP

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include "Components/Link/Transport.hpp"

namespace M2 {

struct Options {
    TransportKind transport = TransportKind::Udp;
    std::uint16_t port = DefaultPort;
    std::uint64_t cycles = 0;
    const char* log = "flight.csv";
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
        } else if (flight && std::strcmp(key, "--cycles") == 0 && readUnsigned(value, number)) {
            options.cycles = number;
        } else if (flight && std::strcmp(key, "--log") == 0 && *value != '\0') {
            options.log = value;
        } else {
            return false;
        }
    }
    return true;
}

}  // namespace M2

#endif
