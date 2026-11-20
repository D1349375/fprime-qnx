#ifndef DRV_QNX_MSG_DRIVER_HPP
#define DRV_QNX_MSG_DRIVER_HPP

#include <cstddef>
#include <cstdint>
#include <sys/dispatch.h>

namespace Drv {

//! Bounded request/reply transport for a local QNX channel, owned by one IPC thread.
class QnxMsgDriver {
  public:
    static constexpr std::size_t MaxPayload = 128;

    QnxMsgDriver() = default;
    ~QnxMsgDriver();
    QnxMsgDriver(const QnxMsgDriver&) = delete;
    QnxMsgDriver& operator=(const QnxMsgDriver&) = delete;

    bool open(bool server, const char* name);
    bool receive(std::uint8_t* payload, std::size_t capacity, std::size_t& size);
    //! Wait up to 10 ms for an unblock pulse for the current request.
    bool waitForPendingUnblock();
    bool reply(const std::uint8_t* payload, std::size_t size);
    void reject();
    bool request(const std::uint8_t* payload,
                 std::size_t size,
                 std::uint8_t* response,
                 std::size_t responseCapacity,
                 std::size_t& responseSize);

  private:
    const char* m_name = nullptr;
    name_attach_t* m_attach = nullptr;
    int m_connection = -1;
    int m_pending = 0;
};

}  // namespace Drv

#endif
