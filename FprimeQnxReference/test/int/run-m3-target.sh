#!/bin/sh
set -eu

[ "$#" -eq 3 ] || exit 2
target_dir="$1"
case "$target_dir" in /tmp/fprime-m3.*) ;; *) exit 2 ;; esac
suffix="${target_dir#/tmp/fprime-m3.}"
case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 2 ;; esac
cd "$target_dir"
scenario="$2"
repair="$3"
case "$scenario:$repair" in
    normal:restart|crash:restart|crash:none|stall:restart|gate:restart|geometry:restart|transport:restart|recovery:restart) ;;
    *) exit 2 ;;
esac

control="/dev/slm-fprime-m3-$suffix"
export LD_LIBRARY_PATH="$target_dir/slm-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Do not carry a log or a control channel forward from a previous SLM process.
[ ! -e "$control" ] && [ ! -e /dev/name/local/fprime-m2 ]
for file in flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log death.csv death.log; do
    : > "$file"
done
sed -e "s|@DIR@|$target_dir|g" -e "s/@SCENARIO@/$scenario/g" -e "s/@REPAIR@/$repair/g" \
    m3-slm.xml.in > m3-slm.xml
ulimit -c 0 || true
monitor=
watcher=
cleanup() {
    if [ -n "$monitor" ] && kill -0 "$monitor" 2>/dev/null; then
        ./slmctl -n "$control" 'stop m3' >/dev/null 2>&1 || true
        kill -TERM "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
    if [ -n "$watcher" ]; then
        kill -TERM "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

if [ "$scenario" = crash ]; then
    ./watch-death > death.csv 2> death.log &
    watcher=$!
    attempt=0
    until grep -q '^ns,pid$' death.csv; do
        if ! kill -0 "$watcher" 2>/dev/null || [ "$attempt" -ge 4 ]; then
            cat death.log >&2
            echo 'QNX process death observer did not become ready' >&2
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
fi

./slm -VV -R 2/min -n "$control" -s m3 -x m3 m3-slm.xml > slm.log 2>&1 &
monitor=$!
attempt=0
until grep -q '^SUMMARY ' flight.log; do
    kill -0 "$monitor"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 16 ]
    sleep 1
done

if [ -n "$watcher" ] && ! kill -0 "$watcher" 2>/dev/null; then
    cat death.log >&2
    echo 'QNX process death observer stopped before the flight summary' >&2
    exit 1
fi
