#!/bin/sh
set -eu

target_dir="$(pwd -P)"
control="/dev/slm-fprime-m2-${target_dir##*.}"
export LD_LIBRARY_PATH="$target_dir/slm-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Allow an orderly test teardown. The deployment template marks FlightSW critical.
sed -e "s|@M2_DIR@|$target_dir|g" -e 's/ launch="critical"//' m2-slm.xml.in > m2-slm.xml

ctl() {
    ./slmctl -n "$control" "$@"
}

await_matches() {
    pattern="$1"
    file="$2"
    minimum="$3"
    attempt=0
    while [ "$(grep -c "$pattern" "$file" 2>/dev/null || true)" -lt "$minimum" ]; do
        kill -0 "$monitor"
        attempt=$((attempt + 1))
        [ "$attempt" -lt 8 ]
        sleep 1
    done
}

read_pid() {
    sed -n 's/^READY pid=\([1-9][0-9]*\) .*/\1/p' "$1" | tail -n 1
}

cleanup() {
    if kill -0 "$monitor" 2>/dev/null; then
        ctl 'stop m2' >/dev/null 2>&1 || true
        kill -TERM "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
}

: > flight.log
: > advisor.log
./slm -VV -n "$control" -s m2 -x m2 m2-slm.xml > slm.log 2>&1 &
monitor=$!
trap cleanup 0
trap 'exit 1' HUP INT TERM
await_matches '^READY ' flight.log 1
await_matches '^RESULT ' advisor.log 3
flight="$(read_pid flight.log)"
advisor="$(read_pid advisor.log)"
[ -n "$flight" ] && [ -n "$advisor" ] && [ "$flight" != "$advisor" ]
ctl "active -p $advisor" | tee slm-before.log
grep -q advisor slm-before.log
printf 'CRASH flight_pid=%s advisor_pid=%s\n' "$flight" "$advisor"
kill -KILL "$advisor"
await_matches '^READY ' advisor.log 2
replacement="$(read_pid advisor.log)"
[ -n "$replacement" ] && [ "$replacement" != "$advisor" ] && [ "$replacement" != "$flight" ]
ctl "active -p $replacement" | tee slm-after.log
grep -q advisor slm-after.log
kill -0 "$flight"
printf 'RESTART flight_pid=%s advisor_pid=%s\n' "$flight" "$replacement"
sleep 1
ctl 'stop m2'
await_matches '^SUMMARY ' flight.log 1
