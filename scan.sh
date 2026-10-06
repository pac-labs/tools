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

readfile() {
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null
    else
        echo "unknown"
    fi
}

firstline() {
    if [ -r "$1" ]; then
        head -n 1 "$1" 2>/dev/null
    else
        echo "unknown"
    fi
}

# Try to determine whether the host's procfs is available.
HOST_PROC_OK=0
if [ -e "$HOST_ROOT/proc/1/ns/net" ]; then
    HOST_PROC_OK=1
fi

# Run a command inside the host network namespace if possible.
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

[ -r "$DMI/sys_vendor" ] &&
    value "Manufacturer" "$(cat "$DMI/sys_vendor")"

[ -r "$DMI/product_name" ] &&
    value "Model" "$(cat "$DMI/product_name")"

[ -r "$DMI/product_version" ] &&
    value "Model version" "$(cat "$DMI/product_version")"

[ -r "$DMI/bios_vendor" ] &&
    value "BIOS vendor" "$(cat "$DMI/bios_vendor")"

[ -r "$DMI/bios_version" ] &&
    value "BIOS version" "$(cat "$DMI/bios_version")"


section "CPU"

if [ -r "$HOST_ROOT/proc/cpuinfo" ]; then

    CPU_MODEL=$(grep -m1 -E 'model name|Hardware|Processor' \
        "$HOST_ROOT/proc/cpuinfo" 2>/dev/null \
        | cut -d: -f2- \
        | sed 's/^[[:space:]]*//')

    CPU_COUNT=$(grep -c '^processor[[:space:]]*:' \
        "$HOST_ROOT/proc/cpuinfo" 2>/dev/null)

    value "CPU model" "${CPU_MODEL:-unknown}"
    value "Logical CPUs" "${CPU_COUNT:-unknown}"
else
    echo "Host /proc/cpuinfo unavailable."
fi


section "MEMORY"

if [ -r "$HOST_ROOT/proc/meminfo" ]; then
    MEMTOTAL=$(awk '/^MemTotal:/ {
        printf "%.1f GiB", $2 / 1024 / 1024
    }' "$HOST_ROOT/proc/meminfo")

    MEMAVAILABLE=$(awk '/^MemAvailable:/ {
        printf "%.1f GiB", $2 / 1024 / 1024
    }' "$HOST_ROOT/proc/meminfo")

    value "Memory total" "${MEMTOTAL:-unknown}"
    value "Memory available" "${MEMAVAILABLE:-unknown}"

    grep -E '^(HugePages_Total|HugePages_Free|Hugepagesize):' \
        "$HOST_ROOT/proc/meminfo" 2>/dev/null || true
else
    echo "Host /proc/meminfo unavailable."
fi


section "STORAGE DEVICES"

if [ -d "$HOST_ROOT/sys/block" ]; then
    for disk in "$HOST_ROOT"/sys/block/*; do
        [ -e "$disk" ] || continue

        name=$(basename "$disk")

        case "$name" in
            loop*|ram*|zram*)
                continue
                ;;
        esac

        sectors=$(cat "$disk/size" 2>/dev/null || echo 0)
        size_gib=$(awk -v s="$sectors" 'BEGIN {
            printf "%.1f GiB", (s * 512) / 1024 / 1024 / 1024
        }')

        model=$(cat "$disk/device/model" 2>/dev/null \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        rotational=$(cat "$disk/queue/rotational" 2>/dev/null)

        case "$rotational" in
            0) media="SSD/NVMe" ;;
            1) media="rotational" ;;
            *) media="unknown" ;;
        esac

        printf "%-12s %-12s %-12s %s\n" \
            "$name" \
            "$size_gib" \
            "$media" \
            "${model:-unknown}"
    done
else
    echo "Host /sys/block unavailable."
fi


section "NETWORK INTERFACES"

NETROOT="$HOST_ROOT/sys/class/net"

if [ -d "$NETROOT" ]; then

    for iface_path in "$NETROOT"/*; do
        [ -e "$iface_path" ] || continue

        iface=$(basename "$iface_path")

        echo
        echo "--- $iface ---"

        value "State" "$(firstline "$iface_path/operstate")"
        value "MAC" "$(firstline "$iface_path/address")"
        value "MTU" "$(firstline "$iface_path/mtu")"

        if [ -r "$iface_path/speed" ]; then
            speed=$(cat "$iface_path/speed" 2>/dev/null)
            case "$speed" in
                ''|-1) speed="unknown" ;;
                *) speed="${speed} Mbit/s" ;;
            esac
            value "Current speed" "$speed"
        fi

        if [ -r "$iface_path/duplex" ]; then
            value "Duplex" "$(cat "$iface_path/duplex" 2>/dev/null)"
        fi

        if [ -r "$iface_path/carrier" ]; then
            carrier=$(cat "$iface_path/carrier" 2>/dev/null)
            case "$carrier" in
                1) carrier="yes" ;;
                0) carrier="no" ;;
            esac
            value "Carrier" "$carrier"
        fi

        # PCI / hardware information
        if [ -e "$iface_path/device" ]; then
            device_path=$(readlink -f "$iface_path/device" 2>/dev/null)

            if [ -n "$device_path" ]; then
                value "Device" "$(basename "$device_path")"
            fi

            if [ -L "$iface_path/device/driver" ]; then
                driver=$(basename "$(readlink "$iface_path/device/driver")")
                value "Driver" "$driver"
            fi

            [ -r "$iface_path/device/vendor" ] &&
                value "PCI vendor" "$(cat "$iface_path/device/vendor")"

            [ -r "$iface_path/device/device" ] &&
                value "PCI device" "$(cat "$iface_path/device/device")"

            [ -r "$iface_path/device/numa_node" ] &&
                value "NUMA node" "$(cat "$iface_path/device/numa_node")"

            if [ -r "$iface_path/device/sriov_totalvfs" ]; then
                value "SR-IOV max VFs" \
                    "$(cat "$iface_path/device/sriov_totalvfs")"
            fi

            if [ -r "$iface_path/device/sriov_numvfs" ]; then
                value "SR-IOV enabled VFs" \
                    "$(cat "$iface_path/device/sriov_numvfs")"
            fi
        fi

        if [ -d "$iface_path/bonding" ]; then
            echo "Bond information:"
            grep . "$iface_path"/bonding/* 2>/dev/null \
                | sed 's/^/  /'
        fi
    done

else
    echo "Host network sysfs unavailable at:"
    echo "$NETROOT"
fi


section "HOST IP ADDRESSES"

if command -v ip >/dev/null 2>&1 &&
   hostnet ip -br address >/dev/null 2>&1; then

    hostnet ip -br address

else
    echo "Live host network namespace unavailable."
    echo
    echo "IPv6 addresses visible through host procfs:"

    if [ -r "$HOST_ROOT/proc/net/if_inet6" ]; then
        cat "$HOST_ROOT/proc/net/if_inet6"
    else
        echo "  unavailable"
    fi
fi


section "HOST ROUTES"

if command -v ip >/dev/null 2>&1 &&
   hostnet ip route >/dev/null 2>&1; then

    echo "IPv4:"
    hostnet ip route

    echo
    echo "IPv6:"
    hostnet ip -6 route 2>/dev/null || true

elif [ -r "$HOST_ROOT/proc/net/route" ]; then

    echo "ip/nsenter unavailable; raw host route table:"
    cat "$HOST_ROOT/proc/net/route"

else
    echo "Host routing information unavailable."
fi


section "DEFAULT ROUTE"

if command -v ip >/dev/null 2>&1; then
    hostnet ip route show default || true
fi


section "NIC LINK CAPABILITIES"

if command -v ethtool >/dev/null 2>&1 &&
   command -v nsenter >/dev/null 2>&1 &&
   [ "$HOST_PROC_OK" -eq 1 ]; then

    for iface_path in "$NETROOT"/*; do
        [ -e "$iface_path" ] || continue

        iface=$(basename "$iface_path")

        [ "$iface" = "lo" ] && continue

        # Avoid dumping ethtool data for virtual interfaces that
        # clearly have no backing device.
        [ -e "$iface_path/device" ] || continue

        echo
        echo "--- $iface ---"

        hostnet ethtool "$iface" 2>/dev/null |
            grep -E \
                '^[[:space:]]*(Supported ports:|Supported link modes:|Advertised link modes:|Speed:|Duplex:|Auto-negotiation:|Port:|Link detected:)'

    done

else
    echo "ethtool/nsenter not available; sysfs link information shown above."
fi


section "DNS"

if [ -r "$HOST_ROOT/etc/resolv.conf" ]; then
    grep -v '^[[:space:]]*#' "$HOST_ROOT/etc/resolv.conf" \
        | grep -v '^[[:space:]]*$'
else
    echo "Host resolv.conf unavailable."
fi


section "NETWORK KERNEL MODULES"

if [ -r "$HOST_ROOT/proc/modules" ]; then
    grep -Ei \
        '(^| )(bonding|bridge|8021q|vxlan|geneve|openvswitch|mlx|ixgbe|i40e|ice|bnxt|ena|virtio_net|e1000|tg3)' \
        "$HOST_ROOT/proc/modules" 2>/dev/null || \
        echo "No commonly recognised network modules found."
else
    echo "Host module list unavailable."
fi


section "NETWORK SUMMARY"

if command -v ip >/dev/null 2>&1 &&
   [ "$HOST_PROC_OK" -eq 1 ] &&
   command -v nsenter >/dev/null 2>&1; then

    echo "Interfaces:"
    hostnet ip -br link

    echo
    echo "Addresses:"
    hostnet ip -br address

    echo
    echo "Default gateway:"
    hostnet ip route show default

else
    echo "Host network namespace could not be entered."
    echo "Hardware information above should still be useful."
fi


echo
echo "======================================================================"
echo "END OF HOST MACHINE REPORT"
echo "======================================================================"