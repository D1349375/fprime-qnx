#!/usr/bin/env bash
# Common QNX SDP 8.0 mkqnximage/QEMU helpers for the validation scripts.

qnx_vm_build_image() {
    local image_dir="$1" hostname="$2" public_key="$3"
    shift 3
    (
        cd "$image_dir" &&
            mkqnximage --noprompt --type=qemu --arch=x86_64 --cpu=2 --ram=1536M \
                --hostname="$hostname" --ssh-ident="$public_key" "$@" --build
    )
}

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
    # The guest uses the libvirt default bridge for DHCP. Without an active network it boots but never
    # gets an address, which otherwise surfaces later as an SSH readiness timeout.
    if command -v virsh >/dev/null 2>&1 && ! timeout 10 virsh -c qemu:///system net-list --name 2>/dev/null |
            grep -qx default; then
        printf 'The libvirt default network is not active, so the guest would get no DHCP address.\n' >&2
        printf 'Start it with: virsh -c qemu:///system net-start default (a stale virbr0 left by a WSL\n' >&2
        printf 'distribution restart must be deleted first: ip link delete virbr0, as root).\n' >&2
        return 1
    fi
    local deadline launch_status
    # The detached launcher can return before QEMU writes its PID file.
    if (cd "$image_dir" && setsid --wait mkqnximage --run=-h) >"$boot_log" 2>&1 < /dev/null; then
        deadline=$((SECONDS + 10))
        while (( SECONDS < deadline )); do
            qnx_vm_running "$image_dir" && return 0
            sleep 0.2
        done
        qnx_vm_running "$image_dir" && return 0
        printf 'QEMU did not create a live PID file within 10 seconds: %s/output/qemu.pid\n' \
            "$image_dir" >>"$boot_log"
    else
        launch_status=$?
        printf 'mkqnximage --run=-h exited with status %s\n' "$launch_status" >>"$boot_log"
    fi

    # Keep launch and environment diagnostics with this guest's other evidence.
    {
        ls -ld /dev/kvm || true
        if command -v ip >/dev/null 2>&1; then
            ip -brief link show virbr0 || true
        fi
        if [[ -s "$image_dir/output/qemu.out" ]]; then
            tail -20 "$image_dir/output/qemu.out"
        fi
    } >>"$boot_log" 2>&1
    printf 'QNX guest launch failed. See %s\n' "$boot_log" >&2
    tail -40 "$boot_log" >&2
    return 1
}

qnx_vm_find_guest() {
    local image_dir="$1"
    shift
    local mac leases guest deadline=$((SECONDS + 120))
    local -a candidates
    mac="$(sed -nE "s/^OPT_MACADDR='([[:xdigit:]:]+)'$/\1/p" "$image_dir/output/options")"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || return 1

    while (( SECONDS < deadline )); do
        # dhcpcd keeps its DUID on the guest's data file system. A boot stopped before that write is
        # committed leaves no DUID, so the next boot sends a new one and gets another lease for the same
        # MAC. Try the latest expiry first and every other lease after it, so a stale lease cannot block
        # readiness. Capture the listing before parsing: an early-exit reader in the pipe could kill
        # virsh with SIGPIPE.
        leases="$(virsh -c qemu:///system net-dhcp-leases default 2>/dev/null)" || leases=""
        mapfile -t candidates < <(printf '%s\n' "$leases" |
            awk -v mac="$mac" 'tolower($3) == tolower(mac) && $4 == "ipv4" {
                sub(/\/.*/, "", $5)
                if ($5 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $1 " " $2 " " $5
            }' | LC_ALL=C sort -r | awk '!seen[$3]++ { print $3 }')
        if (( ${#candidates[@]} == 0 )); then
            guest="$(cd "$image_dir" && mkqnximage --getip 2>/dev/null |
                grep -E '^[0-9]+(\.[0-9]+){3}$' | tail -1)" || guest=""
            [[ -n "$guest" ]] && candidates=("$guest")
        fi
        for guest in "${candidates[@]}"; do
            if ssh "$@" "root@$guest" true > /dev/null 2>&1; then
                printf '%s\n' "$guest"
                return 0
            fi
        done
        sleep 2
    done
    return 1
}
