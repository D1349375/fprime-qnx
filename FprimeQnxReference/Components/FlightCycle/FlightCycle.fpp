module M2 {
  @ Samples the ADCS simulation and commits one estimate per scheduled cycle.
  passive component FlightCycle {
    sync input port run: Svc.Sched
  }
}
