#!/bin/sh
# Run a staged normal scenario under SLM inside the QNX test guest.
set -eu

[ "$#" -eq 4 ] || exit 2
target_dir=$1
endpoint=$2
seed=$3
cycles=$4
case "$target_dir" in /tmp/fprime-gds.*) ;; *) exit 2 ;; esac
suffix=${target_dir#/tmp/fprime-gds.}
case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 2 ;; esac
case "$seed" in ''|0|*[!0-9]*) exit 2 ;; esac
case "$cycles" in ''|*[!0-9]*) exit 2 ;; esac
case "$endpoint" in
    -) gds= ;;
    *[!0-9.:]*) exit 2 ;;
    *:*) gds=" --gds $endpoint" ;;
    *) exit 2 ;;
esac

cd "$target_dir"
control="/dev/slm-fprime-gds-$suffix"
export LD_LIBRARY_PATH="$target_dir/slm-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ ! -e "$control" ] && [ ! -e /dev/name/local/fprime-m2 ]
for file in flight.csv flight.log flight.err advisor.log advisor.err link.csv slm.log; do
    : > "$file"
done
flight_options=" --cycles $cycles --m4-seed $seed$gds"
backoff=1
if [ "$cycles" -eq 0 ] && [ -n "$gds" ]; then
    # Give the ground telemetry rate group time to publish FDIR before SLM restarts the advisor.
    backoff=3
fi
sed -e "s|@DIR@|$target_dir|g" -e 's/@SCENARIO@/normal/g' -e 's/@REPAIR@/restart/g' \
    -e "s/backoff=\"1\"/backoff=\"$backoff\"/" \
    -e "s|@FLIGHT_OPTIONS@|$flight_options|g" -e 's|@ADVISOR_OPTIONS@||g' m3-slm.xml.in > gds-slm.xml
ulimit -c 0 || true

monitor=
cleanup() {
    if [ -n "$monitor" ] && kill -0 "$monitor" 2>/dev/null; then
        ./slmctl -n "$control" 'stop m3' >/dev/null 2>&1 || true
        kill -TERM "$monitor" 2>/dev/null || true
        wait "$monitor" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

./slm -VV -R 2/min -n "$control" -s m3 -x m3 gds-slm.xml >slm.log 2>&1 &
monitor=$!
while ! grep -q '^SUMMARY ' flight.log; do
    kill -0 "$monitor"
    sleep 1
done
grep -q '^SUMMARY .* exit_ok=1$' flight.log
