#!/bin/sh
set -eu

transport="$1"
flight=
advisor=
cleanup() {
    if [ -n "$advisor" ]; then
        kill -TERM "$advisor" 2>/dev/null || true
        wait "$advisor" 2>/dev/null || true
    fi
    if [ -n "$flight" ]; then
        kill -TERM "$flight" 2>/dev/null || true
        wait "$flight" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

./FlightSW --transport "$transport" --cycles 200 --log flight.csv > flight.log 2>&1 &
flight=$!
attempt=0
while ! grep -q '^READY ' flight.log; do
    kill -0 "$flight"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 4 ]
    sleep 1
done
# Keep the consumer offline long enough for the four-slot snapshot queue to fill.
sleep 1
./MlAdvisor --transport "$transport" > advisor.log 2>&1 &
advisor=$!
sleep 1
kill -TERM "$advisor"
wait "$advisor"
advisor=
wait "$flight"
flight=
