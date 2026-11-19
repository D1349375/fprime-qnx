#!/usr/bin/env bash
# Common QNX SDP 8.0 mkqnximage/QEMU helpers for the validation scripts.

qnx_vm_running() {
    local image_dir="$1" pid
    [[ -r "$image_dir/output/qemu.pid" ]] || return 1
    read -r pid < "$image_dir/output/qemu.pid"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$image_dir" ]] || return 1
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == qemu-system-* ]]
}

qnx_vm_start() {
    local image_dir="$1" boot_log="$2" pid
    qnx_vm_running "$image_dir" && return 0
    if [[ -r "$image_dir/output/qemu.pid" ]]; then
        read -r pid < "$image_dir/output/qemu.pid"
        # The SDK stopper uses this PID directly. Leave a live, unexpected process alone.
        if [[ "$pid" =~ ^[1-9][0-9]*$ && -d "/proc/$pid" ]]; then
            printf 'Unexpected live PID %s in %s/output/qemu.pid\n' "$pid" "$image_dir" >&2
            return 1
        fi
    fi
    # Detach the SDK's headless QEMU from the calling WSL session.
    (cd "$image_dir" && setsid --wait mkqnximage --run=-h) >"$boot_log" 2>&1 < /dev/null
}

qnx_vm_find_guest() {
    local image_dir="$1"
    shift
    local mac guest deadline=$((SECONDS + 120))
    mac="$(sed -nE "s/^OPT_MACADDR='([[:xdigit:]:]+)'$/\1/p" "$image_dir/output/options")"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || return 1

    while (( SECONDS < deadline )); do
        guest="$(virsh -c qemu:///system net-dhcp-leases default 2>/dev/null |
            awk -v mac="$mac" 'tolower($3) == tolower(mac) && $4 == "ipv4" { sub(/\/.*/, "", $5); print $5; exit }')" ||
            guest=""
        if [[ -z "$guest" ]]; then
            guest="$(cd "$image_dir" && mkqnximage --getip 2>/dev/null |
                grep -E '^[0-9]+(\.[0-9]+){3}$' | tail -1)" || guest=""
        fi
        if [[ -n "$guest" ]] && ssh "$@" "root@$guest" true > /dev/null 2>&1; then
            printf '%s\n' "$guest"
            return 0
        fi
        sleep 2
    done
    return 1
}
