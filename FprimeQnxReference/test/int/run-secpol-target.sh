#!/bin/sh
set -eu

[ "$#" -eq 1 ] || exit 2
target_dir=$1
case "$target_dir" in /tmp/fprime-secpol.*) ;; *) exit 2 ;; esac
suffix=${target_dir#/tmp/fprime-secpol.}
case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 2 ;; esac
cd "$target_dir"
export LD_LIBRARY_PATH="$target_dir/slm-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
control="/dev/slm-fprime-policy-$suffix"
[ ! -e /dev/name/local/fprime-m2 ] && [ ! -e /dev/fprime/gate ]
chmod 755 "$target_dir" gate-open-probe
touch advisor.log advisor.err
chown 65534:65534 advisor.log advisor.err
test -r /proc/boot/secpol.bin
./secpolpush
sed -e "s|@DIR@|$target_dir|g" -e 's/@SCENARIO@/normal/g' -e 's/@REPAIR@/restart/g' \
    -e 's|@FLIGHT_OPTIONS@| --gate-status|g' -e 's|@ADVISOR_OPTIONS@||g' \
    -e '/<SLM:component name="flight">/a\
    <SLM:type>fprime_flight_t</SLM:type>
' \
    -e '/<SLM:component name="advisor">/a\
    <SLM:type>fprime_advisor_t</SLM:type>\
    <SLM:user>65534:65534</SLM:user>
' m3-slm.xml.in >slm.xml
ulimit -c 0 || true

monitor=
cleanup() {
    if [ -n "$monitor" ] && kill -0 "$monitor" 2>/dev/null; then
        ./slmctl -n "$control" 'stop m3' >/dev/null 2>&1 || true
        kill -TERM "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
    for file in slm.log flight.err advisor.err; do
        if [ -s "$file" ]; then
            printf '\n%s\n' "$file"
            tail -20 "$file"
        fi
    done
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
./slm -VV -R 2/min -n "$control" -s m3 -x m3 slm.xml >slm.log 2>&1 &
monitor=$!
attempt=0
until grep -q '^RESULT session=[1-9]' advisor.log 2>/dev/null; do
    kill -0 "$monitor"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 45 ] || { echo 'Typed advisor did not deliver a hub result' >&2; exit 1; }
    sleep 0.1
done
advisor_pid=$(sed -n 's/^READY pid=\([0-9][0-9]*\).*/\1/p' advisor.log | head -1)
case "$advisor_pid" in ''|0|1|*[!0-9]*) exit 1 ;; esac
pidin -p "$advisor_pid" -f an_ >advisor-type.txt
grep -Eq '[[:space:]]fprime_advisor_t[[:space:]]*$' advisor-type.txt
attempt=0
while :; do
    on -T fprime_observer_t -u 65534:65534 "$target_dir/gate-open-probe" read >gate-control.txt
    if grep -Fxq 'advisor=active' gate-control.txt; then break; fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || { echo 'FlightSW did not adopt the typed advisor result' >&2; exit 1; }
    sleep 0.1
done
on -T fprime_advisor_t -u 65534:65534 "$target_dir/gate-open-probe" denied >gate-denied.txt
grep -Fxq 'Gate open denied by permissions for uid=65534' gate-denied.txt
printf '%s\n' 'PASS restricted advisor delivered a native hub result' 'PASS same-UID control read the listening Gate endpoint' 'PASS advisor type was denied at the Gate endpoint'
