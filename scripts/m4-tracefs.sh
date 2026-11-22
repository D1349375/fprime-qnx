#!/usr/bin/env bash
# Delegate one tracefs instance to the user running the ADCS test.
set -euo pipefail
if [[ $# != 1 || $EUID != 0 ]]; then
    echo 'Usage: sudo scripts/m4-tracefs.sh USER' >&2
    exit 2
fi
owner="$(id -u "$1"):$(id -g "$1")"
tracefs=/sys/kernel/tracing/instances
mountpoint="$(mktemp -d /run/fprime-adcs-trace.XXXXXXXX)"
instance="$tracefs/${mountpoint##*/}"
created=0
mounted=0
sleeper=
cleanup() {
    if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; fi
    if (( mounted )); then umount -- "$mountpoint"; fi
    if (( created )); then
        printf '0\n' >"$instance/tracing_on"
        rmdir -- "$instance"
    fi
    rmdir -- "$mountpoint"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
mkdir -- "$instance"
created=1
printf '0\n' >"$instance/tracing_on"
chown "$owner" "$instance" "$instance/"{tracing_on,trace,trace_clock,buffer_size_kb} \
    "$instance/events/sched/sched_switch/"{filter,enable} "$instance/events/sched/sched_wakeup/"{filter,enable}
mount --bind "$instance" "$mountpoint"
mounted=1
printf 'M4_HOST_TRACEFS=%s\n' "$mountpoint"
sleep infinity &
sleeper=$!
wait "$sleeper"
