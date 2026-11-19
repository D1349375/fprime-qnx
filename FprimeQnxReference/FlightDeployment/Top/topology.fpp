module M2Flight {
  instance timer: Svc.QnxTimer base id 0x0000
  instance rateGroup: Svc.PassiveRateGroup base id 0x0100
  instance flight: M2.FlightCycle base id 0x0200
  instance hubLink: M2.HubLink base id 0x0300
  instance hub: Svc.GenericHub base id 0x0400

  deployment topology Flight {
    instance timer
    instance rateGroup
    instance flight
    instance hubLink
    instance hub

    connections Timing {
      timer.CycleOut -> rateGroup.CycleIn
      rateGroup.RateGroupMemberOut[0] -> flight.run
    }

    include "../../Components/Link/connections.fppi"
  }
}
