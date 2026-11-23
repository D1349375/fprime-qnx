#ifndef M2_FLIGHT_TOPOLOGY_DEFS_HPP
#define M2_FLIGHT_TOPOLOGY_DEFS_HPP

#include "Svc/Subtopologies/CdhCore/PingEntries.hpp"
#include "Svc/Subtopologies/CdhCore/SubtopologyTopologyDefs.hpp"
#include "Svc/Subtopologies/ComCcsds/SubtopologyTopologyDefs.hpp"

namespace PingEntries {
struct M2Flight_groundRate1 {
    enum { WARN = 3, FATAL = 5 };
};
struct M2Flight_groundRate2 {
    enum { WARN = 3, FATAL = 5 };
};
struct M2Flight_groundRate3 {
    enum { WARN = 3, FATAL = 5 };
};
}  // namespace PingEntries

namespace M2Flight {

struct TopologyState {
    const char* hostname;
    U16 port;
    CdhCore::SubtopologyState cdhCore;
    ComCcsds::SubtopologyState comCcsds;
};

namespace PingEntries = ::PingEntries;
}  // namespace M2Flight

#endif
