module M2Advisor {
  instance hubLink: M2.HubLink base id 0x0000
  instance hub: Svc.GenericHub base id 0x0100

  deployment topology Advisor {
    instance hubLink
    instance hub

    include "../../Components/Link/connections.fppi"
  }
}
