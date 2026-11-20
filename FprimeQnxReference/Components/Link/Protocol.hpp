#ifndef M2_PROTOCOL_HPP
#define M2_PROTOCOL_HPP

#include <array>
#include <cstdint>
#include <time.h>

namespace M2 {

constexpr std::uint64_t NanosecondsPerSecond = 1000000000;
constexpr std::uint64_t PeriodNs = 20000000;
constexpr std::uint64_t FreshnessNs = 250000000;
constexpr std::uint16_t DefaultPort = 50100;
using SensorReadings = std::array<std::uint16_t, 6>;

enum class MessageType : std::uint8_t { Request = 1, Snapshot, Result, Ack, Wait };

struct Packet {
    MessageType type = MessageType::Wait;
    std::uint64_t client = 0;
    std::uint64_t session = 0;
    std::uint64_t cycle = 0;
    bool flag = false;
    SensorReadings sensors{};
    std::uint8_t action = 0;
    std::uint8_t channel = 0;
};

using WirePacket = std::array<std::uint8_t, 44>;

WirePacket encode(const Packet& packet);
bool decode(const WirePacket& wire, Packet& packet);
std::uint64_t monotonicNs();
timespec toTimespec(std::uint64_t ns);

}  // namespace M2

#endif
