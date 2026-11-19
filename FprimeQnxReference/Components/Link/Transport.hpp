#ifndef M2_TRANSPORT_HPP
#define M2_TRANSPORT_HPP

#include <netinet/in.h>
#include "Components/Link/HubLink.hpp"
#include "Drv/QnxMsgDriver/QnxMsgDriver.hpp"

namespace M2 {

enum class TransportKind { Udp, Qnx };

inline const char* transportName(TransportKind kind) {
    return kind == TransportKind::Qnx ? "qnx" : "udp";
}

class Transport {
  public:
    Transport() = default;
    ~Transport();
    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;

    bool open(TransportKind kind, bool server, std::uint16_t port);
    bool receive(HubFrame& frame);
    bool send(const HubFrame& frame);
    bool exchange(const HubFrame& request, HubFrame& response);
    void reject();

  private:
    TransportKind m_kind = TransportKind::Udp;
    Drv::QnxMsgDriver m_qnx;
    int m_socket = -1;
    bool m_server = false;
    sockaddr_in m_peer{};
};

}  // namespace M2

#endif
