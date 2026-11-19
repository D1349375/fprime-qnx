// ======================================================================
// \title  QnxTimer.cpp
// \brief  cpp file for the QnxTimer component implementation class
//
// \copyright
// Copyright 2026 fprime-qnx contributors. Licensed under the Apache License, Version 2.0.
// ======================================================================

#include <errno.h>
#include <sys/neutrino.h>
#include <sys/siginfo.h>
#include <cstring>

#include <Fw/FPrimeBasicTypes.hpp>
#include <Fw/Logger/Logger.hpp>
#include <Svc/QnxTimer/QnxTimer.hpp>

namespace Svc {

namespace {
//! Pulse code delivered by the periodic timer
constexpr int PULSE_CODE_TICK = _PULSE_CODE_MINAVAIL;
//! Pulse code sent by quit() to wake the timer loop immediately
constexpr int PULSE_CODE_QUIT = _PULSE_CODE_MINAVAIL + 1;
}  // namespace

QnxTimer ::QnxTimer(const char* const compName)
    : QnxTimerComponentBase(compName),
      m_quit(false),
      m_coid(-1),
      m_chid(-1),
      m_timerId(),
      m_timerCreated(false),
      m_overruns(0),
      m_rawTimeErrorLogged(false),
      m_overrunLogged(false) {}

QnxTimer ::~QnxTimer() {
    this->cleanup();
}

void QnxTimer ::quit() {
    this->m_quit.store(true);
    const int coid = this->m_coid.load();
    if (coid != -1) {
        // Best effort: if the pulse cannot be sent the loop still exits on the next tick
        (void)MsgSendPulse(coid, SIGEV_PULSE_PRIO_INHERIT, PULSE_CODE_QUIT, 0);
    }
}

U64 QnxTimer ::getOverrunCount() const {
    return this->m_overruns.load();
}

void QnxTimer ::cleanup() {
    if (this->m_timerCreated) {
        (void)timer_delete(this->m_timerId);
        this->m_timerCreated = false;
    }
    const int coid = this->m_coid.exchange(-1);
    if (coid != -1) {
        (void)ConnectDetach(coid);
    }
    if (this->m_chid != -1) {
        (void)ChannelDestroy(this->m_chid);
        this->m_chid = -1;
    }
}

void QnxTimer ::startTimer(const Fw::TimeInterval& interval) {
    this->runTimer(interval, nullptr);
}

void QnxTimer ::startTimerAt(const Fw::TimeInterval& interval, const struct timespec& firstRelease) {
    this->runTimer(interval, &firstRelease);
}

void QnxTimer ::runTimer(const Fw::TimeInterval& interval, const struct timespec* firstRelease) {
    // Private channel: only this process can attach to it
    this->m_chid = ChannelCreate(_NTO_CHF_PRIVATE);
    if (this->m_chid == -1) {
        Fw::Logger::log("QnxTimer ChannelCreate error: %s\n", strerror(errno));
        return;
    }
    const int coid = ConnectAttach(0, 0, this->m_chid, _NTO_SIDE_CHANNEL, 0);
    if (coid == -1) {
        Fw::Logger::log("QnxTimer ConnectAttach error: %s\n", strerror(errno));
        this->cleanup();
        return;
    }
    this->m_coid.store(coid);

    // quit() may have been called before the connection existed
    if (this->m_quit.load()) {
        this->cleanup();
        return;
    }

    struct sigevent event;
    SIGEV_PULSE_INIT(&event, coid, SIGEV_PULSE_PRIO_INHERIT, PULSE_CODE_TICK, 0);
    if (timer_create(CLOCK_MONOTONIC, &event, &this->m_timerId) == -1) {
        Fw::Logger::log("QnxTimer timer_create error: %s\n", strerror(errno));
        this->cleanup();
        return;
    }
    this->m_timerCreated = true;

    const time_t seconds = static_cast<time_t>(interval.getSeconds());
    FW_ASSERT(static_cast<U32>(seconds) == interval.getSeconds());
    struct itimerspec itval;
    itval.it_interval.tv_sec = seconds;
    itval.it_interval.tv_nsec = static_cast<long>(interval.getUSeconds()) * 1000L;
    itval.it_value = firstRelease == nullptr ? itval.it_interval : *firstRelease;
    const int flags = firstRelease == nullptr ? 0 : TIMER_ABSTIME;
    if (timer_settime(this->m_timerId, flags, &itval, nullptr) == -1) {
        Fw::Logger::log("QnxTimer timer_settime error: %s\n", strerror(errno));
        this->cleanup();
        return;
    }

    while (true) {
        struct _pulse pulse;
        const int rcvid = MsgReceivePulse(this->m_chid, &pulse, sizeof(pulse), nullptr);
        if (rcvid == -1) {
            if (errno == EINTR) {
                continue;
            }
            // A non-interrupt receive error will not clear itself; stop rather than spin on it
            Fw::Logger::log("QnxTimer MsgReceivePulse error: %s\n", strerror(errno));
            break;
        }
        if (this->m_quit.load() || pulse.code == PULSE_CODE_QUIT) {
            break;
        }
        if (pulse.code != PULSE_CODE_TICK) {
            continue;
        }
        const int overrun = timer_getoverrun(this->m_timerId);
        if (overrun > 0) {
            this->m_overruns.fetch_add(static_cast<U64>(overrun));
            if (!this->m_overrunLogged) {
                this->m_overrunLogged = true;
                Fw::Logger::log("QnxTimer missed %d tick(s); further overruns are counted silently\n", overrun);
            }
        }
        const Os::RawTime::Status rawTimeStatus = this->m_rawTime.now();
        if ((rawTimeStatus != Os::RawTime::Status::OP_OK) && !this->m_rawTimeErrorLogged) {
            this->m_rawTimeErrorLogged = true;
            Fw::Logger::log("QnxTimer raw time error: %d\n", static_cast<I32>(rawTimeStatus));
        }
        this->CycleOut_out(0, this->m_rawTime);
    }
    this->cleanup();
}

}  // end namespace Svc
