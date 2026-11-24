
# QNX message priority inheritance

A QNX server thread can inherit the sender's priority when receiving a message. A channel created with `_NTO_CHF_FIXED_PRIORITY` opts out. After replying to a message, the receive thread's priority stays at the inherited level until a higher-priority send, a lower-priority receive or an explicit scheduling change adjusts it. These are QNX API semantics. [QNX System Architecture](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.sys_arch/topic/ipc_Priority_inheritance_messages.html) · [QNX ChannelCreate reference](https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.lib_ref/topic/c/channelcreate.html)

The ADCS design puts native message handling on the IPC worker and keeps the periodic flight thread behind a bounded handoff. Project target coverage is the IPC behavior and flight/advisor process boundary in the [evidence index](evidence-index.md#qnx-mechanisms).
