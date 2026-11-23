// ======================================================================
// \title  QnxTimer.hpp
// \brief  hpp file for the QnxTimer component implementation class
//
// \copyright
// Copyright 2026 fprime-qnx contributors. Licensed under the Apache License, Version 2.0.
// ======================================================================

#ifndef Svc_QnxTimer_HPP
#define Svc_QnxTimer_HPP

#include <time.h>
#include <atomic>

#include "Fw/Time/TimeInterval.hpp"
#include "Os/RawTime.hpp"
#include "Svc/QnxTimer/QnxTimerComponentAc.hpp"

namespace Svc {

//! Rate-group timer for QNX.
//!
//! startTimer() creates a private channel, attaches a side-channel connection to it, and arms a periodic
//! timer_create(CLOCK_MONOTONIC) timer whose expiry is delivered as a pulse. The calling thread then blocks in
//! MsgReceivePulse() and emits CycleOut once per tick until quit() is called. quit() is safe to call from a
//! signal handler: it only stores an atomic flag and sends a wake-up pulse.
//!
//! The public API matches Svc::LinuxTimer so existing topologies can switch the instance type without other changes.
class QnxTimer final : public QnxTimerComponentBase {
  public:
    //! Construct object QnxTimer
    explicit QnxTimer(const char* const compName  //!< The component name
    );

    //! Destroy object QnxTimer
    ~QnxTimer();

    //! Start the timer and emit CycleOut every interval. Blocks the calling thread until quit() is called.
    void startTimer(const Fw::TimeInterval& interval);

    //! Start on a CLOCK_MONOTONIC release grid. One-shot expirations skip elapsed releases
    //! and rearm for the next future release on the same grid.
    void startTimerAt(const Fw::TimeInterval& interval, const struct timespec& firstRelease);

    //! Preserve the receiving thread's priority on this timer's channel. Call before starting the timer.
    void useFixedPriority() { m_fixedPriority = true; }

    //! Request the timer loop to exit. Async-signal-safe.
    void quit();

    //! Number of timer expirations that were not delivered as separate pulses (from timer_getoverrun)
    U64 getOverrunCount() const;

  private:
    void runTimer(const Fw::TimeInterval& interval, const struct timespec* firstRelease);

    //! Release the timer, connection, and channel if they were created
    void cleanup();

    std::atomic<bool> m_quit;     //!< set by quit(), read by the timer loop
    std::atomic<int> m_coid;      //!< connection id used to send the wake-up pulse; -1 when not running
    bool m_fixedPriority = false;
    int m_chid;                   //!< private channel id; -1 when not created
    timer_t m_timerId;            //!< POSIX timer
    bool m_timerCreated;          //!< true once timer_create succeeded
    std::atomic<U64> m_overruns;  //!< accumulated timer overruns
    Os::RawTime m_rawTime;        //!< timestamp passed to CycleOut
    bool m_rawTimeErrorLogged;    //!< latch so a persistent raw time failure is logged once
    bool m_overrunLogged;         //!< latch so the first overrun is reported once
};

}  // end namespace Svc

#endif
