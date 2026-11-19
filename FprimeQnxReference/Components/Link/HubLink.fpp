module M2 {
  @ Bridges the worker-owned transport and one GenericHub buffer port.
  passive component HubLink {
    output port toHub: Fw.BufferSend
    sync input port returnToApp: Fw.BufferSend
    sync input port fromHub: Fw.BufferSend
    output port returnFromHub: Fw.BufferSend
    sync input port outbound: Fw.BufferSend
    output port returnOutbound: Fw.BufferSend
    output port inbound: Fw.BufferSend
    sync input port returnInbound: Fw.BufferSend
    sync input port allocate: Fw.BufferGet
    sync input port deallocate: Fw.BufferSend
  }
}
