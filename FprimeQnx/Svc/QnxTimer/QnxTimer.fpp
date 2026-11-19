module Svc {

  @ A QNX interval timer that drives rate groups. A periodic POSIX timer on CLOCK_MONOTONIC delivers a QNX pulse to a
  @ private channel each period; every pulse produces one CycleOut call. Drop-in replacement for Svc.LinuxTimer.
  passive component QnxTimer {

    @ implement tick interface
    import Drv.Tick

  }

}
