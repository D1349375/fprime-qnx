#!/bin/sh
# Capture the M5 ring around a single scenario and export it after flight completes.
set -eu

[ "$#" -eq 5 ] || exit 2
case "$1" in /tmp/fprime-m3.*) ;; *) exit 2 ;; esac
suffix="${1#/tmp/fprime-m3.}"
case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 2 ;; esac
cd "$1"

trace="/dev/shmem/fprime-m3-$suffix.kev"
rm -f "$trace" trace.kev
ln -s "$trace" trace.kev
: >trace-status.txt
./tracelogger -r -F1 -F2 -k 192 -v -f "$trace" >tracelogger.log 2>&1 &
tracer=$!
scenario=
cleanup() {
    if [ -n "$scenario" ]; then
        kill -TERM "$scenario" 2>/dev/null || true
        wait "$scenario" 2>/dev/null || true
    fi
    if [ -n "$tracer" ] && kill -0 "$tracer" 2>/dev/null; then
        kill -TERM "$tracer" 2>/dev/null || true
        wait "$tracer" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

wait_rc=0
before_rc=0
after_rc=0
stop_rc=0
logger_rc=0
scenario_rc=0
waitfor "$trace" 2 || wait_rc=$?
./trace-control anchor >trace-anchor.txt 2>trace-control.log || before_rc=$?
if [ "${M4_TRACE_WATCH:-0}" = 1 ]; then
    rm -f trace-trigger.txt trace-scenario-status.txt
    : >flight.log
    : >flight.csv
    (
        rc=0
        sh ./run-m3-target.sh "$@" || rc=$?
        printf '%s\n' "$rc" >trace-scenario-status.txt
        exit "$rc"
    ) </dev/null >&2 &
    scenario=$!
    monitor_rc=0
    ./trace-control stream || monitor_rc=$?
    wait "$scenario" || scenario_rc=$?
    scenario=
    if [ "$scenario_rc" -eq 0 ]; then scenario_rc=$monitor_rc; fi
else
    sh ./run-m3-target.sh "$@" || scenario_rc=$?
fi
./trace-control anchor >>trace-anchor.txt 2>>trace-control.log || after_rc=$?
if [ "${M4_TRACE_WATCH:-0}" != 1 ] || [ ! -s trace-trigger.txt ]; then
    ./trace-control stop >>trace-control.log 2>&1 || stop_rc=$?
fi
if [ "$stop_rc" -ne 0 ]; then
    kill -INT "$tracer" 2>/dev/null || true
fi
wait "$tracer" || logger_rc=$?
tracer=
printf 'wait_exit=%d before_exit=%d after_exit=%d stop_exit=%d tracelogger_exit=%d\n' \
    "$wait_rc" "$before_rc" "$after_rc" "$stop_rc" "$logger_rc" >trace-status.txt
exit "$scenario_rc"
