#include "Components/Link/HubLink.hpp"

#include <algorithm>
#include <Fw/Types/Assert.hpp>

namespace M2 {

HubLink::HubLink(const char* name) : HubLinkComponentBase(name) {}

void HubLink::configure() {
    // Derive the allowed GenericHub header from its own buffer encoder.
    WirePacket probe{};
    emit(probe);
    m_canonical = m_outbound;
    FW_ASSERT(m_canonical.size > probe.size());
}

void HubLink::emit(WirePacket& wire) {
    m_outbound.size = 0;
    Fw::Buffer payload(wire.data(), wire.size());
    toHub_out(0, payload);
    FW_ASSERT(!m_allocated);
}

HubFrame HubLink::wrap(const Packet& packet) {
    auto wire = encode(packet);
    emit(wire);
    return m_outbound;
}

bool HubLink::unwrap(HubFrame& frame, Packet& packet) {
    const auto headerSize = m_canonical.size - m_payload.size();
    if (frame.size != m_canonical.size ||
        !std::equal(m_canonical.data.data(), m_canonical.data.data() + headerSize, frame.data.data())) {
        return false;
    }
    m_received = false;
    Fw::Buffer inbound(frame.data.data(), frame.size);
    inbound_out(0, inbound);
    return m_received && decode(m_payload, packet);
}

void HubLink::returnToApp_handler(FwIndexType, Fw::Buffer&) {}

void HubLink::fromHub_handler(FwIndexType, Fw::Buffer& buffer) {
    if (buffer.getSize() == m_payload.size()) {
        std::copy_n(buffer.getData(), buffer.getSize(), m_payload.begin());
        m_received = true;
    }
    returnFromHub_out(0, buffer);
}

void HubLink::outbound_handler(FwIndexType, Fw::Buffer& buffer) {
    FW_ASSERT(buffer.getSize() <= HubFrameCapacity);
    m_outbound.size = buffer.getSize();
    std::copy_n(buffer.getData(), m_outbound.size, m_outbound.data.begin());
    returnOutbound_out(0, buffer);
}

void HubLink::returnInbound_handler(FwIndexType, Fw::Buffer&) {}

Fw::Buffer HubLink::allocate_handler(FwIndexType, FwSizeType size) {
    FW_ASSERT(!m_allocated && size <= m_storage.size());
    m_allocated = true;
    return Fw::Buffer(m_storage.data(), size);
}

void HubLink::deallocate_handler(FwIndexType, Fw::Buffer&) {
    FW_ASSERT(m_allocated);
    m_allocated = false;
}

}  // namespace M2
