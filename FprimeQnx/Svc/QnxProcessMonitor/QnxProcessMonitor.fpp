module Svc {

  @ Reports QNX process-manager death notifications for a watched local process.
  passive component QnxProcessMonitor {
    time get port timeCaller
    event port eventOut
    text event port textEventOut

    event ProcessDied(pid: U32, name: string size 32) \
      severity warning high id 0 \
      format "Process {} ({}) died"
  }

}
