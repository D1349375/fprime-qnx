#include "Svc/QnxProcessMonitor/QnxProcessMonitor.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <sys/neutrino.h>
#include <sys/procmgr.h>
#include <system_error>
#include <time.h>

namespace Svc {
namespace {

constexpr int DeathPulse = _PULSE_CODE_MINAVAIL;
// Bound the join even when no death pulse arrives during shutdown.
constexpr std::uint64_t ReceiveTimeoutNs = 250000000;

}  // namespace

QnxProcessMonitor::QnxProcessMonitor(const char* name) : QnxProcessMonitorComponentBase(name) {}

QnxProcessMonitor::~QnxProcessMonitor() {
    stop();
}

bool QnxProcessMonitor::setupError(const char* operation) {
    std::perror(operation);
    stop();
    return false;
}

bool QnxProcessMonitor::start() {
    if (m_worker.joinable()) {
        return false;
    }
    m_channel = ChannelCreate(_NTO_CHF_PRIVATE | _NTO_CHF_FIXED_PRIORITY);
    if (m_channel == -1) {
        return setupError("QnxProcessMonitor ChannelCreate");
    }
    m_connection = ConnectAttach(0, 0, m_channel, _NTO_SIDE_CHANNEL, _NTO_COF_CLOEXEC);
    if (m_connection == -1) {
        return setupError("QnxProcessMonitor ConnectAttach");
    }

    SIGEV_PULSE_INIT(&m_event, m_connection, SIGEV_PULSE_PRIO_INHERIT, DeathPulse, 0);
    SIGEV_MAKE_UPDATEABLE(&m_event);
    if (MsgRegisterEvent(&m_event, SYSMGR_COID) == -1) {
        return setupError("QnxProcessMonitor MsgRegisterEvent");
    }
    m_registered = true;

    // Use the process-manager recipe from watch-death.c with a per-instance subscription handle.
    m_subscription = procmgr_event_notify_add(PROCMGR_EVENT_PROCESS_DEATH, &m_event);
    if (m_subscription == -1) {
        return setupError("QnxProcessMonitor procmgr_event_notify_add");
    }

    m_stopping.store(false, std::memory_order_release);
    try {
        m_worker = std::thread(&QnxProcessMonitor::receiveDeaths, this);
    } catch (const std::system_error& error) {
        std::fprintf(stderr, "QnxProcessMonitor receiver: %s\n", error.what());
        stop();
        return false;
    }
    return true;
}

void QnxProcessMonitor::watch(U32 pid, const char* name) {
    std::lock_guard<std::mutex> lock(m_watchMutex);
    if (m_stopping.load(std::memory_order_relaxed)) {
        return;
    }
    m_pid = pid;
    m_name = Fw::LogStringArg(name);
}

void QnxProcessMonitor::receiveDeaths() {
    while (!m_stopping.load(std::memory_order_acquire)) {
        if (TimerTimeout(CLOCK_MONOTONIC, _NTO_TIMEOUT_RECEIVE, nullptr, &ReceiveTimeoutNs, nullptr) == -1) {
            std::perror("QnxProcessMonitor TimerTimeout");
            return;
        }
        struct _pulse pulse {};
        if (MsgReceivePulse(m_channel, &pulse, sizeof(pulse), nullptr) == -1) {
            if (errno == EINTR || errno == ETIMEDOUT) {
                continue;
            }
            std::perror("QnxProcessMonitor MsgReceivePulse");
            return;
        }
        if (m_stopping.load(std::memory_order_acquire)) {
            return;
        }
        if (pulse.code != DeathPulse || pulse.value.sival_int <= 0) {
            continue;
        }
        const auto pid = static_cast<U32>(pulse.value.sival_int);
        Fw::LogStringArg name;
        {
            std::lock_guard<std::mutex> lock(m_watchMutex);
            if (m_pid != pid) {
                continue;
            }
            name = m_name;
            m_pid = 0;
        }
        log_WARNING_HI_ProcessDied(pid, name);
    }
}

void QnxProcessMonitor::stop() {
    m_stopping.store(true, std::memory_order_release);
    if (m_worker.joinable()) {
        m_worker.join();
    }
    if (m_subscription != -1) {
        if (procmgr_event_notify_delete(m_subscription) == -1) {
            std::perror("QnxProcessMonitor procmgr_event_notify_delete");
        }
        m_subscription = -1;
    }
    if (m_registered) {
        if (MsgUnregisterEvent(&m_event) == -1) {
            std::perror("QnxProcessMonitor MsgUnregisterEvent");
        }
        m_registered = false;
    }
    if (m_connection != -1) {
        if (ConnectDetach(m_connection) == -1) {
            std::perror("QnxProcessMonitor ConnectDetach");
        }
        m_connection = -1;
    }
    if (m_channel != -1) {
        if (ChannelDestroy(m_channel) == -1) {
            std::perror("QnxProcessMonitor ChannelDestroy");
        }
        m_channel = -1;
    }
    std::lock_guard<std::mutex> lock(m_watchMutex);
    m_pid = 0;
}

}  // namespace Svc
