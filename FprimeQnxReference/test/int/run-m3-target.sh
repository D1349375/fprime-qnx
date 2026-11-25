#!/bin/sh
set -eu

case "$#" in 3|5|6) ;; *) exit 2 ;; esac
target_dir="$1"
case "$target_dir" in /tmp/fprime-m3.*) ;; *) exit 2 ;; esac
suffix="${target_dir#/tmp/fprime-m3.}"
case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 2 ;; esac
cd "$target_dir"
scenario="$2"
repair="$3"
case "$scenario:$repair" in
    normal:restart|crash:restart|crash:none|stall:restart|gate:restart|geometry:restart|transport:restart|recovery:restart|drift:restart) ;;
    *) exit 2 ;;
esac

flight_options=
advisor_options=
entry=m3
if [ "$#" -ge 5 ]; then
    case "$4" in ''|0|*[!0-9]*) exit 2 ;; esac
    flight_options=" --m4-seed $4"
    if [ "$#" -eq 6 ]; then
        case "$6" in ''|*[!0-9.eE+-]*) exit 2 ;; esac
        flight_options="$flight_options --drift-cutoff $6"
        case "$scenario:$5" in
            normal:fdir|drift:fdir) entry=flight ;;
            normal:learned|drift:learned) advisor_options=" --drift-model $target_dir/model.txt" ;;
            *) exit 2 ;;
        esac
    else
        case "$scenario:$5" in
            normal:fdir|recovery:fdir|crash:fdir) entry=flight ;;
            normal:learned|recovery:learned|crash:learned) advisor_options=" --model $target_dir/model.txt" ;;
            *) exit 2 ;;
        esac
    fi
fi

runtime_case=${M3_RUNTIME_CASE:-default}
case "$runtime_case:$scenario:$repair" in
    default:*) ;;
    address-space:crash:restart) advisor_options="$advisor_options --address-space-mib 128" ;;
    q3-unbudgeted:stall:restart|q3-sporadic:stall:restart)
        advisor_options="$advisor_options --cpu-load ${runtime_case#q3-}"
        flight_options="$flight_options --check-cpu0"
        ;;
    *) exit 2 ;;
esac
if [ "$scenario" = drift ] && [ "$#" -ne 6 ]; then exit 2; fi

control="/dev/slm-fprime-m3-$suffix"
export LD_LIBRARY_PATH="$target_dir/slm-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Do not carry a log or a control channel forward from a previous SLM process.
[ ! -e "$control" ] && [ ! -e /dev/name/local/fprime-m2 ]
crash_marker=
if [ "$scenario" = crash ]; then
    crash_marker="/dev/shmem/fprime-m3-crash-$suffix"
    rm -f "$crash_marker"
    advisor_options="$advisor_options --crash-marker $crash_marker"
fi
for file in flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log death.csv death.log; do
    : > "$file"
done
sed -e "s|@DIR@|$target_dir|g" -e "s/@SCENARIO@/$scenario/g" -e "s/@REPAIR@/$repair/g" \
    -e "s|@FLIGHT_OPTIONS@|$flight_options|g" -e "s|@ADVISOR_OPTIONS@|$advisor_options|g" \
    m3-slm.xml.in > m3-slm.xml
case "$runtime_case" in
    q3-*)
        sed '/<SLM:component name=/a\
    <SLM:runmask>1</SLM:runmask>
' m3-slm.xml > m3-shared-cpu.xml
        mv m3-shared-cpu.xml m3-slm.xml
        ;;
esac
ulimit -c 0 || true
monitor=
watcher=
cleanup() {
    if [ -n "$monitor" ] && kill -0 "$monitor" 2>/dev/null; then
        ./slmctl -n "$control" "stop $entry" >/dev/null 2>&1 || true
        kill -TERM "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
    if [ -n "$watcher" ]; then
        kill -TERM "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    fi
    if [ -n "$crash_marker" ]; then
        rm -f "$crash_marker"
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

./slm -VV -R 2/min -n "$control" -s "$entry" -x "$entry" m3-slm.xml > slm.log 2>&1 &
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
