connections Hub {
  hubLink.toHub -> hub.bufferIn[0]
  hub.bufferInReturn[0] -> hubLink.returnToApp
  hub.bufferOut[0] -> hubLink.fromHub
  hubLink.returnFromHub -> hub.bufferOutReturn[0]
  hub.toBufferDriver -> hubLink.outbound
  hubLink.returnOutbound -> hub.toBufferDriverReturn
  hubLink.inbound -> hub.fromBufferDriver
  hub.fromBufferDriverReturn -> hubLink.returnInbound
  hub.allocate -> hubLink.allocate
  hub.deallocate -> hubLink.deallocate
}
