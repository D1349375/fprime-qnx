module M2 {
  enum ControlSource : U8 {
    ML = 0
    FDIR = 1
  }

  @ Reports flight state from the logger thread
  passive component FlightGround {
    sync input port transportReady: Drv.ByteStreamReady
    output port transportReadyOut: Drv.ByteStreamReady

    time get port timeCaller
    event port eventOut
    text event port textEventOut
    telemetry port tlmOut

    event FdirEngaged(reason: string size 32) \
      severity warning high id 0 \
      format "FDIR engaged: {}"

    event AdvisorAccepted(session: U64) \
      severity activity high id 1 \
      format "Advisor session accepted: {}"

    event AdviceRejected(reason: string size 32) \
      severity warning low id 2 \
      format "Advice rejected: {}" \
      throttle 5

    event GateDecision(rule: string size 24, verdict: string size 16) \
      severity activity low id 3 \
      format "Gate {}: {}" \
      throttle 10

    telemetry ControlSource: ControlSource id 0
    telemetry AdvisorSession: U64 id 1
    telemetry AttitudeErrorDeg: F32 id 2 update on change
  }
}
