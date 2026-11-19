#ifndef M2_HUB_LINK_HPP
#define M2_HUB_LINK_HPP

#include "Components/Link/HubLinkComponentAc.hpp"
#include "Components/Link/Protocol.hpp"

namespace M2 {

constexpr std::size_t HubFrameCapacity = 128;
struct HubFrame {
    std::array<U8, HubFrameCapacity + 1U> data{};
    std::size_t size = 0;
};

//! Used only on the IPC worker or advisor thread. All buffer ownership returns synchronously.
class HubLink final : public HubLinkComponentBase {
  public:
    explicit HubLink(const char* name);
    void configure();
    HubFrame wrap(const Packet& packet);
    bool unwrap(HubFrame& frame, Packet& packet);

  private:
    void emit(WirePacket& wire);
    void returnToApp_handler(FwIndexType port, Fw::Buffer& buffer) override;
    void fromHub_handler(FwIndexType port, Fw::Buffer& buffer) override;
    void outbound_handler(FwIndexType port, Fw::Buffer& buffer) override;
    void returnInbound_handler(FwIndexType port, Fw::Buffer& buffer) override;
    Fw::Buffer allocate_handler(FwIndexType port, FwSizeType size) override;
    void deallocate_handler(FwIndexType port, Fw::Buffer& buffer) override;

    std::array<U8, HubFrameCapacity> m_storage{};
    bool m_allocated = false;
    HubFrame m_canonical{};
    HubFrame m_outbound{};
    WirePacket m_payload{};
    bool m_received = false;
};

}  // namespace M2

#endif
