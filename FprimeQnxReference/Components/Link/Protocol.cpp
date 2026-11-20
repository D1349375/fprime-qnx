#include "Components/Link/Protocol.hpp"

#include <cstdlib>

namespace M2 {
namespace {

// Network byte order keeps integer fields independent of native alignment and width.
void write64(WirePacket& wire, std::size_t offset, std::uint64_t value) {
    for (std::size_t i = 0; i < 8; ++i) {
        wire[offset + 7 - i] = static_cast<std::uint8_t>(value & 0xffU);
        value >>= 8U;
    }
}

std::uint64_t read64(const WirePacket& wire, std::size_t offset) {
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < 8; ++i) {
        value = (value << 8U) | wire[offset + i];
    }
    return value;
}

}  // namespace

WirePacket encode(const Packet& packet) {
    WirePacket wire{};
    wire[0] = 'M';
    wire[1] = '2';
    wire[2] = 1;
    wire[3] = static_cast<std::uint8_t>(packet.type);
    wire[4] = packet.flag ? 1 : 0;
    wire[5] = packet.action;
    wire[6] = packet.channel;
    write64(wire, 8, packet.client);
    write64(wire, 16, packet.session);
    write64(wire, 24, packet.cycle);
    for (std::size_t i = 0; i < packet.sensors.size(); ++i) {
        wire[32 + 2 * i] = static_cast<std::uint8_t>(packet.sensors[i] >> 8U);
        wire[33 + 2 * i] = static_cast<std::uint8_t>(packet.sensors[i] & 0xffU);
    }
    return wire;
}

bool decode(const WirePacket& wire, Packet& packet) {
    if (wire[0] != 'M' || wire[1] != '2' || wire[2] != 1 || wire[4] > 1 ||
        wire[7] != 0 ||
        wire[3] < static_cast<std::uint8_t>(MessageType::Request) ||
        wire[3] > static_cast<std::uint8_t>(MessageType::Wait)) {
        return false;
    }
    packet.type = static_cast<MessageType>(wire[3]);
    if (packet.type != MessageType::Result && (wire[5] != 0 || wire[6] != 0)) {
        return false;
    }
    packet.flag = wire[4] != 0;
    packet.action = wire[5];
    packet.channel = wire[6];
    packet.client = read64(wire, 8);
    packet.session = read64(wire, 16);
    packet.cycle = read64(wire, 24);
    for (std::size_t i = 0; i < packet.sensors.size(); ++i) {
        packet.sensors[i] = static_cast<std::uint16_t>((wire[32 + 2 * i] << 8U) | wire[33 + 2 * i]);
        if (packet.sensors[i] > 1000) {
            return false;
        }
    }
    return packet.client != 0;
}

std::uint64_t monotonicNs() {
    timespec now{};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        std::abort();
    }
    return static_cast<std::uint64_t>(now.tv_sec) * NanosecondsPerSecond +
           static_cast<std::uint64_t>(now.tv_nsec);
}

timespec toTimespec(std::uint64_t ns) {
    return {static_cast<time_t>(ns / NanosecondsPerSecond), static_cast<long>(ns % NanosecondsPerSecond)};
}

}  // namespace M2
