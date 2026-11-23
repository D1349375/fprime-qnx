module M2Flight {
  instance timer: Svc.QnxTimer base id 0x0000
  instance rateGroup: Svc.PassiveRateGroup base id 0x0100
  instance flight: M2.FlightCycle base id 0x0200
  instance hubLink: M2.HubLink base id 0x0300
  instance hub: Svc.GenericHub base id 0x0400
  instance ground: M2.FlightGround base id 0x0500

  instance groundTimer: Svc.QnxTimer base id 0x1000
  instance groundDriver: Svc.RateGroupDriver base id 0x1100
  instance groundRate1: Svc.ActiveRateGroup base id 0x1200 \
    queue size 10 \
    stack size 64 * 1024 \
    priority 43
  instance groundRate2: Svc.ActiveRateGroup base id 0x1300 \
    queue size 10 \
    stack size 64 * 1024 \
    priority 42
  instance groundRate3: Svc.ActiveRateGroup base id 0x1400 \
    queue size 10 \
    stack size 64 * 1024 \
    priority 41
  instance posixTime: Svc.PosixTime base id 0x1500
  instance comDriver: Drv.TcpClient base id 0x1600
  instance processMonitor: Svc.QnxProcessMonitor base id 0x1700

  deployment topology Flight {
    instance timer
    instance rateGroup
    instance flight
    instance hubLink
    instance hub
    instance ground
    instance groundTimer
    instance groundDriver
    instance groundRate1
    instance groundRate2
    instance groundRate3
    instance posixTime
    instance comDriver
    instance processMonitor
    instance CdhCore.Subtopology
    instance ComCcsds.Subtopology

    command connections instance CdhCore.cmdDisp
    event connections instance CdhCore.events
    telemetry connections instance CdhCore.tlmSend
    text event connections instance CdhCore.textLogger
    health connections instance CdhCore.$health
    time connections instance posixTime

    connections Timing {
      timer.CycleOut -> rateGroup.CycleIn
      rateGroup.RateGroupMemberOut[0] -> flight.run
    }

    include "../../Components/Link/connections.fppi"

    connections GroundRates {
      groundTimer.CycleOut -> groundDriver.CycleIn

      groundDriver.CycleOut[0] -> groundRate1.CycleIn
      groundRate1.RateGroupMemberOut[0] -> CdhCore.Subtopology.tlmSendRun
      groundRate1.RateGroupMemberOut[1] -> CdhCore.Subtopology.cmdDispRun
      groundRate1.RateGroupMemberOut[2] -> ComCcsds.Subtopology.comQueueRun
      groundRate1.RateGroupMemberOut[3] -> ComCcsds.Subtopology.aggregatorTimeout

      groundDriver.CycleOut[1] -> groundRate2.CycleIn
      groundRate2.RateGroupMemberOut[0] -> CdhCore.Subtopology.eventsRun

      groundDriver.CycleOut[2] -> groundRate3.CycleIn
      groundRate3.RateGroupMemberOut[0] -> CdhCore.Subtopology.healthRun
      groundRate3.RateGroupMemberOut[1] -> ComCcsds.Subtopology.bufferManagerSchedIn
    }

    connections Communications {
      comDriver.allocate -> ComCcsds.Subtopology.commsBufferGetCallee
      comDriver.deallocate -> ComCcsds.Subtopology.commsBufferSendIn
      comDriver.$recv -> ComCcsds.Subtopology.drvReceiveIn
      ComCcsds.Subtopology.drvReceiveReturnOut -> comDriver.recvReturnIn
      ComCcsds.Subtopology.drvSendOut -> comDriver.$send
      comDriver.ready -> ground.transportReady
      ground.transportReadyOut -> ComCcsds.Subtopology.drvConnected
    }

    connections ComCcsds_CdhCore {
      CdhCore.Subtopology.eventsPktSend -> ComCcsds.Subtopology.comPacketQueueIn[ComCcsds.Ports_ComPacketQueue.EVENTS]
      CdhCore.Subtopology.tlmSendPktSend -> ComCcsds.Subtopology.comPacketQueueIn[ComCcsds.Ports_ComPacketQueue.TELEMETRY]
      ComCcsds.Subtopology.commandOut -> CdhCore.Subtopology.seqCmdBuff
      CdhCore.Subtopology.seqCmdStatus -> ComCcsds.Subtopology.cmdResponseIn
    }
  }
}
