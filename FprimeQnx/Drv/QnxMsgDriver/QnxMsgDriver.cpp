#include "Drv/QnxMsgDriver/QnxMsgDriver.hpp"

#include <array>
#include <cerrno>
#include <cstring>
#include <sys/iomsg.h>
#include <sys/neutrino.h>
#include <time.h>

namespace Drv {
namespace {

constexpr std::uint16_t AppMessage = _IO_MAX + 1;
constexpr std::uint64_t TimeoutNs = 100000000;

bool setTimeout(int flags, std::uint64_t timeout = TimeoutNs) {
    return TimerTimeout(CLOCK_MONOTONIC, flags, nullptr, &timeout, nullptr) != -1;
}

}  // namespace

QnxMsgDriver::~QnxMsgDriver() {
    reject();
    if (m_connection != -1) {
        name_close(m_connection);
    }
    if (m_attach != nullptr) {
        name_detach(m_attach, 0);
    }
}

bool QnxMsgDriver::open(bool server, const char* name) {
    m_name = name;
    if (server) {
        m_attach = name_attach(nullptr, name, 0);
        return m_attach != nullptr;
    }
    return true;
}

bool QnxMsgDriver::receive(std::uint8_t* payload, std::size_t capacity, std::size_t& size) {
    if (m_attach == nullptr || m_pending != 0) {
        return false;
    }
    std::array<std::uint8_t, sizeof(AppMessage) + MaxPayload> message{};
    _msg_info info{};
    if (!setTimeout(_NTO_TIMEOUT_RECEIVE)) {
        return false;
    }
    const int rcvid = MsgReceive(m_attach->chid, message.data(), message.size(), &info);
    if (rcvid < 0) {
        return false;
    }
    if (rcvid == 0) {
        _pulse pulse{};
        static_assert(sizeof(pulse) <= message.size(), "receive buffer must also fit a pulse");
        std::memcpy(&pulse, message.data(), sizeof(pulse));
        if (pulse.code == _PULSE_CODE_DISCONNECT) {
            ConnectDetach(pulse.scoid);
        }
        return false;
    }

    std::uint16_t type = 0;
    if (info.msglen >= sizeof(type)) {
        std::memcpy(&type, message.data(), sizeof(type));
    }
    if (type == _IO_CONNECT) {
        MsgReply(rcvid, EOK, nullptr, 0);
        return false;
    }
    if (type != AppMessage || info.srcmsglen != info.msglen || info.msglen <= sizeof(type) ||
        info.msglen - sizeof(type) > capacity) {
        MsgError(rcvid, EBADMSG);
        return false;
    }
    size = info.msglen - sizeof(type);
    std::memcpy(payload, message.data() + sizeof(type), size);
    m_pending = rcvid;
    m_senderPid = info.pid;
    return true;
}

bool QnxMsgDriver::waitForPendingUnblock() {
    constexpr std::uint64_t ProbeTimeoutNs = 10000000;
    if (m_pending == 0 || !setTimeout(_NTO_TIMEOUT_RECEIVE, ProbeTimeoutNs)) {
        return false;
    }
    _pulse pulse{};
    if (MsgReceivePulse(m_attach->chid, &pulse, sizeof(pulse), nullptr) != 0) {
        return false;
    }
    if (pulse.code == _PULSE_CODE_DISCONNECT) {
        ConnectDetach(pulse.scoid);
    }
    return pulse.code == _PULSE_CODE_UNBLOCK && pulse.value.sival_int == m_pending;
}

bool QnxMsgDriver::reply(const std::uint8_t* payload, std::size_t size) {
    if (m_pending == 0 || size == 0 || size > MaxPayload) {
        reject();
        return false;
    }
    const int rcvid = m_pending;
    m_pending = 0;
    return MsgReply(rcvid, static_cast<int>(size), payload, size) == 0;
}

void QnxMsgDriver::reject() {
    if (m_pending != 0) {
        MsgError(m_pending, EBADMSG);
        m_pending = 0;
    }
}

bool QnxMsgDriver::request(const std::uint8_t* payload,
                           std::size_t size,
                           std::uint8_t* response,
                           std::size_t responseCapacity,
                           std::size_t& responseSize) {
    if (m_name == nullptr || size == 0 || size > MaxPayload) {
        return false;
    }
    if (m_connection == -1) {
        m_connection = name_open(m_name, 0);
    }
    if (m_connection == -1) {
        return false;
    }
    std::array<std::uint8_t, sizeof(AppMessage) + MaxPayload> message{};
    std::memcpy(message.data(), &AppMessage, sizeof(AppMessage));
    std::memcpy(message.data() + sizeof(AppMessage), payload, size);
    if (!setTimeout(_NTO_TIMEOUT_SEND | _NTO_TIMEOUT_REPLY)) {
        return false;
    }
    const int received = MsgSend(m_connection, message.data(), sizeof(AppMessage) + size, response, responseCapacity);
    if (received <= 0 || static_cast<std::size_t>(received) > responseCapacity) {
        name_close(m_connection);
        m_connection = -1;
        return false;
    }
    responseSize = static_cast<std::size_t>(received);
    return true;
}

}  // namespace Drv
