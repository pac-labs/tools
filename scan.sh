#!/bin/sh

# host-specs.sh
#
# Read-only host inventory/report intended to run from a container
# where the host filesystem is mounted at /host-root.
#
# Optional tools that improve the report:
#   ip
#   nsenter
#   ethtool
#   kubectl (optional live cluster summary)
#
# Usage:
#   sh host-specs.sh
#
# Or:
#   HOST_ROOT=/host-root sh host-specs.sh

HOST_ROOT="${HOST_ROOT:-/host-root}"

section() {
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

value() {
    printf "%-24s %s\n" "$1:" "$2"
}

firstline() {
    if [ -r "$1" ]; then
        head -n 1 "$1" 2>/dev/null
    else
        echo "unknown"
    fi
}


count_dirs() {
    count=0
    dir="$1"

    [ -d "$dir" ] || {
        echo 0
        return
    }

    for item in "$dir"/*; do
        [ -d "$item" ] || continue
        count=$((count + 1))
    done

    echo "$count"
}

process_present() {
    wanted="$1"

    for comm in "$HOST_ROOT"/proc/[0-9]*/comm; do
        [ -r "$comm" ] || continue
        name=$(cat "$comm" 2>/dev/null)
        [ "$name" = "$wanted" ] && return 0
    done

    return 1
}

HOST_PROC_OK=0
if [ -e "$HOST_ROOT/proc/1/ns/net" ]; then
    HOST_PROC_OK=1
fi

hostnet() {
    if [ "$HOST_PROC_OK" -eq 1 ] && command -v nsenter >/dev/null 2>&1; then
        nsenter --net="$HOST_ROOT/proc/1/ns/net" -- "$@" 2>/dev/null
        return $?
    fi
    return 127
}

echo "HOST MACHINE REPORT"
echo "Generated: $(date 2>/dev/null || echo unknown)"
echo "Host root: $HOST_ROOT"

section "SYSTEM"

if [ -r "$HOST_ROOT/etc/os-release" ]; then
    OS_NAME=$(grep '^PRETTY_NAME=' "$HOST_ROOT/etc/os-release" 2>/dev/null \
        | head -1 \
        | cut -d= -f2- \
        | sed 's/^"//;s/"$//')
    value "OS" "${OS_NAME:-unknown}"
fi

if [ -r "$HOST_ROOT/proc/sys/kernel/hostname" ]; then
    value "Hostname" "$(cat "$HOST_ROOT/proc/sys/kernel/hostname")"
elif [ -r "$HOST_ROOT/etc/hostname" ]; then
    value "Hostname" "$(cat "$HOST_ROOT/etc/hostname")"
fi

if [ -r "$HOST_ROOT/proc/sys/kernel/osrelease" ]; then
    value "Kernel" "$(cat "$HOST_ROOT/proc/sys/kernel/osrelease")"
fi

DMI="$HOST_ROOT/sys/class/dmi/id"

[ -r "$DMI/sys_vendor" ] && value "Manufacturer" "$(cat "$DMI/sys_vendor")"
[ -r "$DMI/product_name" ] && value "Model" "$(cat "$DMI/product_name")"
[ -r "$DMI/product_version" ] && value "Model version" "$(cat "$DMI/product_version")"
[ -r "$DMI/bios_vendor" ] && value "BIOS vendor" "$(cat "$DMI/bios_vendor")"
[ -r "$DMI/bios_version" ] && value "BIOS version" "$(cat "$DMI/bios_version")"

section "CPU"

if [ -r "$HOST_ROOT/proc/cpuinfo" ]; then
    CPU_MODEL=$(grep -m1 -E 'model name|Hardware|Processor' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null \
        | cut -d: -f2- \
        | sed 's/^[[:space:]]*//')
    CPU_COUNT=$(grep -c '^processor[[:space:]]*:' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null)
    value "CPU model" "${CPU_MODEL:-unknown}"
    value "Logical CPUs" "${CPU_COUNT:-unknown}"
else
    echo "Host /proc/cpuinfo unavailable."
fi

section "MEMORY"

if [ -r "$HOST_ROOT/proc/meminfo" ]; then
    MEMTOTAL=$(awk '/^MemTotal:/ { printf "%.1f GiB", $2 / 1024 / 1024 }' "$HOST_ROOT/proc/meminfo")
    MEMAVAILABLE=$(awk '/^MemAvailable:/ { printf "%.1f GiB", $2 / 1024 / 1024 }' "$HOST_ROOT/proc/meminfo")
    value "Memory total" "${MEMTOTAL:-unknown}"
    value "Memory available" "${MEMAVAILABLE:-unknown}"
    grep -E '^(HugePages_Total|HugePages_Free|Hugepagesize):' "$HOST_ROOT/proc/meminfo" 2>/dev/null || true
else
    echo "Host /proc/meminfo unavailable."
fi

section "STORAGE DEVICES"

if [ -d "$HOST_ROOT/sys/block" ]; then
    for disk in "$HOST_ROOT"/sys/block/*; do
        [ -e "$disk" ] || continue
        name=$(basename "$disk")
        case "$name" in
            loop*|ram*|zram*) continue ;;
        esac
        sectors=$(cat "$disk/size" 2>/dev/null || echo 0)
        size_gib=$(awk -v s="$sectors" 'BEGIN { printf "%.1f GiB", (s * 512) / 1024 / 1024 / 1024 }')
        model=$(cat "$disk/device/model" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rotational=$(cat "$disk/queue/rotational" 2>/dev/null)
        case "$rotational" in
            0) media="SSD/NVMe" ;;
            1) media="rotational" ;;
            *) media="unknown" ;;
        esac
        printf "%-12s %-12s %-12s %s\n" "$name" "$size_gib" "$media" "${model:-unknown}"
    done