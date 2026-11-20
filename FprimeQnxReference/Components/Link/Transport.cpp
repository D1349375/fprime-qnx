#include "Components/Link/Transport.hpp"

#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace M2 {

Transport::~Transport() {
    if (m_socket != -1) {
        close(m_socket);
    }
}

bool Transport::open(TransportKind kind, bool server, std::uint16_t port) {
    m_kind = kind;
    if (kind == TransportKind::Qnx) {
        return m_qnx.open(server, "fprime-m2");
    }
    m_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (m_socket == -1) {
        return false;
    }
    m_server = server;
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    auto* endpoint = reinterpret_cast<sockaddr*>(&address);
    return (server ? bind(m_socket, endpoint, sizeof(address)) :
                     connect(m_socket, endpoint, sizeof(address))) == 0;
}

bool Transport::receive(HubFrame& frame) {
    if (m_kind == TransportKind::Qnx) {
        return m_qnx.receive(frame.data.data(), HubFrameCapacity, frame.size);
    }
    pollfd descriptor{m_socket, POLLIN, 0};
    if (poll(&descriptor, 1, 100) <= 0 || !(descriptor.revents & POLLIN)) {
        return false;
    }
    socklen_t length = sizeof(m_peer);
    const auto size = recvfrom(m_socket, frame.data.data(), frame.data.size(), 0,
                               reinterpret_cast<sockaddr*>(&m_peer), &length);
    if (size <= 0 || static_cast<std::size_t>(size) > HubFrameCapacity) {
        return false;
    }
    frame.size = static_cast<std::size_t>(size);
    return true;
}

bool Transport::send(const HubFrame& frame) {
    if (m_kind == TransportKind::Qnx) {
        return m_qnx.reply(frame.data.data(), frame.size);
    }
    const auto written = m_server
        ? sendto(m_socket, frame.data.data(), frame.size, 0, reinterpret_cast<sockaddr*>(&m_peer), sizeof(m_peer))
        : ::send(m_socket, frame.data.data(), frame.size, 0);
    return written >= 0 && static_cast<std::size_t>(written) == frame.size;
}

bool Transport::exchange(const HubFrame& request, HubFrame& response) {
    if (m_kind == TransportKind::Qnx) {
        return m_qnx.request(request.data.data(), request.size, response.data.data(), HubFrameCapacity, response.size);
    }
    return send(request) && receive(response);
}

bool Transport::waitForPendingUnblock() {
    return m_kind == TransportKind::Qnx && m_qnx.waitForPendingUnblock();
}

void Transport::reject() {
    if (m_kind == TransportKind::Qnx) {
        m_qnx.reject();
    }
}

}  // namespace M2
