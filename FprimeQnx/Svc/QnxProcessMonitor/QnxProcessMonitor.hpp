#ifndef SVC_QNX_PROCESS_MONITOR_HPP
#define SVC_QNX_PROCESS_MONITOR_HPP

#include <atomic>
#include <mutex>
#include <signal.h>
#include <thread>

#include "Fw/Log/LogString.hpp"
#include "Svc/QnxProcessMonitor/QnxProcessMonitorComponentAc.hpp"

namespace Svc {

//! Single-process watch backed by a private QNX pulse receiver thread.
class QnxProcessMonitor final : public QnxProcessMonitorComponentBase {
  public:
    explicit QnxProcessMonitor(const char* name);
    ~QnxProcessMonitor();

    //! Start after wiring the event ports. The owner serializes start and stop.
    bool start();

    //! Replace the current watch, or clear it with PID 0. Call from a non-flight thread
    //! while the monitor is started. The first matching pulse consumes the watch.
    void watch(U32 pid, const char* name);

    //! Stop delivery and release this instance's registration before tearing down the event ports.
    void stop();

  private:
    void receiveDeaths();
    bool setupError(const char* operation);

    int m_channel = -1;
    int m_connection = -1;
    int m_subscription = -1;
    struct sigevent m_event {};
    bool m_registered = false;

    std::thread m_worker;
    std::atomic<bool> m_stopping{true};
    std::mutex m_watchMutex;
    U32 m_pid = 0;
    Fw::LogStringArg m_name;
};

}  // namespace Svc

#endif
