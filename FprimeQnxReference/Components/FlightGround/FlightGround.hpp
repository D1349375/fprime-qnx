#ifndef M2_FLIGHT_GROUND_HPP
#define M2_FLIGHT_GROUND_HPP

#include <atomic>

#include "Components/FlightGround/FlightGroundComponentAc.hpp"

namespace M2 {

struct CycleRecord;

class FlightGround final : public FlightGroundComponentBase {
  public:
    explicit FlightGround(const char* name);

    // Both callbacks are called only by FlightSW's logger.
    void observe(const CycleRecord& row);
    void observeLink(const char* event);

  private:
    void transportReady_handler(FwIndexType portNum) override;

    std::atomic<bool> m_publishSnapshot{false};
    bool m_fdir = true;
    bool m_sourcePublished = false;
    U64 m_session = 0;
    const char* m_lastGate = "";
    const char* m_lastRejection = "";
};

}  // namespace M2

#endif
