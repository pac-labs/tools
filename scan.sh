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

        if [ -e "$iface_path/device" ]; then
            device_path=$(readlink -f "$iface_path/device" 2>/dev/null)
            [ -n "$device_path" ] && value "Device" "$(basename "$device_path")"

            if [ -L "$iface_path/device/driver" ]; then
                driver=$(basename "$(readlink "$iface_path/device/driver")")
                value "Driver" "$driver"
            fi

            [ -r "$iface_path/device/vendor" ] && value "PCI vendor" "$(cat "$iface_path/device/vendor")"
            [ -r "$iface_path/device/device" ] && value "PCI device" "$(cat "$iface_path/device/device")"
            [ -r "$iface_path/device/numa_node" ] && value "NUMA node" "$(cat "$iface_path/device/numa_node")"
            [ -r "$iface_path/device/sriov_totalvfs" ] && value "SR-IOV max VFs" "$(cat "$iface_path/device/sriov_totalvfs")"
            [ -r "$iface_path/device/sriov_numvfs" ] && value "SR-IOV enabled VFs" "$(cat "$iface_path/device/sriov_numvfs")"
        fi

        if [ -d "$iface_path/bonding" ]; then
            echo "Bond information:"
            grep . "$iface_path"/bonding/* 2>/dev/null | sed 's/^/  /'
        fi
    done
else
    echo "Host network sysfs unavailable at:"
    echo "$NETROOT"
fi

section "HOST IP ADDRESSES"

if command -v ip >/dev/null 2>&1 && hostnet ip -br address >/dev/null 2>&1; then
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

if command -v ip >/dev/null 2>&1 && hostnet ip route >/dev/null 2>&1; then
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

if command -v ethtool >/dev/null 2>&1 && command -v nsenter >/dev/null 2>&1 && [ "$HOST_PROC_OK" -eq 1 ]; then
    for iface_path in "$NETROOT"/*; do
        [ -e "$iface_path" ] || continue
        iface=$(basename "$iface_path")
        [ "$iface" = "lo" ] && continue
        [ -e "$iface_path/device" ] || continue
        echo
        echo "--- $iface ---"
        hostnet ethtool "$iface" 2>/dev/null | grep -E '^[[:space:]]*(Supported ports:|Supported link modes:|Advertised link modes:|Speed:|Duplex:|Auto-negotiation:|Port:|Link detected:)'
    done
else
    echo "ethtool/nsenter not available; sysfs link information shown above."
fi

section "DNS"

if [ -r "$HOST_ROOT/etc/resolv.conf" ]; then
    grep -v '^[[:space:]]*#' "$HOST_ROOT/etc/resolv.conf" | grep -v '^[[:space:]]*$'
else
    echo "Host resolv.conf unavailable."
fi

section "NETWORK KERNEL MODULES"

if [ -r "$HOST_ROOT/proc/modules" ]; then
    grep -Ei '(^| )(bonding|bridge|8021q|vxlan|geneve|openvswitch|mlx|ixgbe|i40e|ice|bnxt|ena|virtio_net|e1000|tg3)' "$HOST_ROOT/proc/modules" 2>/dev/null || echo "No commonly recognised network modules found."
else
    echo "Host module list unavailable."
fi

section "NETWORK SUMMARY"

if command -v ip >/dev/null 2>&1 && [ "$HOST_PROC_OK" -eq 1 ] && command -v nsenter >/dev/null 2>&1; then
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



section "KUBERNETES / TALOS LOCAL NODE"

K8S_DETECTED=0

if [ -d "$HOST_ROOT/var/lib/kubelet" ]; then
    K8S_DETECTED=1
    value "Kubelet state" "present"
    value "Kubelet pod directories" "$(count_dirs "$HOST_ROOT/var/lib/kubelet/pods")"
else
    value "Kubelet state" "not found under host-root"
fi

if [ -d "$HOST_ROOT/var/lib/containerd" ] || [ -e "$HOST_ROOT/run/containerd/containerd.sock" ]; then
    K8S_DETECTED=1
    value "Container runtime" "containerd detected"
fi

echo
echo "Host Kubernetes processes:"
PROCESS_COUNT=0
for procname in \
    kubelet \
    containerd \
    kube-apiserver \
    kube-controller-manager \
    kube-scheduler \
    kube-proxy \
    etcd \
    flanneld \
    cilium-agent \
    calico-node \
    ovn-controller
do
    if process_present "$procname"; then
        printf "  %-26s present\n" "$procname"
        PROCESS_COUNT=$((PROCESS_COUNT + 1))
        K8S_DETECTED=1
    fi
done

if [ "$PROCESS_COUNT" -eq 0 ]; then
    echo "  No common Kubernetes process names visible in host /proc."
fi

echo
echo "Runtime sockets:"
SOCKET_COUNT=0
for socket in \
    "$HOST_ROOT/run/containerd/containerd.sock" \
    "$HOST_ROOT/var/run/containerd/containerd.sock" \
    "$HOST_ROOT/run/crio/crio.sock" \
    "$HOST_ROOT/var/run/crio/crio.sock"
do
    if [ -e "$socket" ]; then
        printf "  %s\n" "${socket#"$HOST_ROOT"}"
        SOCKET_COUNT=$((SOCKET_COUNT + 1))
    fi
done

if [ "$SOCKET_COUNT" -eq 0 ]; then
    echo "  No common CRI/runtime socket visible."
fi

for taskdir in \
    "$HOST_ROOT/run/containerd/io.containerd.runtime.v2.task/k8s.io" \
    "$HOST_ROOT/var/run/containerd/io.containerd.runtime.v2.task/k8s.io"
do
    if [ -d "$taskdir" ]; then
        value "Running k8s.io tasks" "$(count_dirs "$taskdir")"
        break
    fi
done

echo
echo "Kubelet configuration:"
KUBELET_CONFIG_FOUND=0
for kubelet_config in \
    "$HOST_ROOT/var/lib/kubelet/config.yaml" \
    "$HOST_ROOT/etc/kubernetes/kubelet-config.yaml"
do
    [ -r "$kubelet_config" ] || continue

    KUBELET_CONFIG_FOUND=1
    printf "  file: %s\n" "${kubelet_config#"$HOST_ROOT"}"

    grep -E '^[[:space:]]*(clusterDomain|clusterDNS|cgroupDriver|maxPods|podPidsLimit|serializeImagePulls|staticPodPath|containerRuntimeEndpoint):' \
        "$kubelet_config" 2>/dev/null \
        | sed 's/^/    /'
done

if [ "$KUBELET_CONFIG_FOUND" -eq 0 ]; then
    echo "  No conventional kubelet config file visible."
fi

echo
echo "Static pod manifests:"
STATIC_COUNT=0
for manifest_dir in \
    "$HOST_ROOT/etc/kubernetes/manifests" \
    "$HOST_ROOT/var/lib/kubelet/manifests"
do
    [ -d "$manifest_dir" ] || continue

    for manifest in "$manifest_dir"/*; do
        [ -f "$manifest" ] || continue
        printf "  %s/%s\n" "${manifest_dir#"$HOST_ROOT"}" "$(basename "$manifest")"
        STATIC_COUNT=$((STATIC_COUNT + 1))
        K8S_DETECTED=1
    done
done

if [ "$STATIC_COUNT" -eq 0 ]; then
    echo "  No conventional static pod manifests visible."
fi

if [ -d "$HOST_ROOT/var/lib/etcd/member" ]; then
    value "Local etcd data" "present"
    value "Likely node role" "control-plane"
fi

echo
echo "CNI configuration:"
CNI_CONFIG_FOUND=0
for cni_dir in \
    "$HOST_ROOT/etc/cni/net.d" \
    "$HOST_ROOT/var/lib/cni"
do
    [ -d "$cni_dir" ] || continue

    printf "  directory: %s\n" "${cni_dir#"$HOST_ROOT"}"

    if [ "$cni_dir" = "$HOST_ROOT/etc/cni/net.d" ]; then
        for cni_file in "$cni_dir"/*; do
            [ -f "$cni_file" ] || continue
            printf "    config: %s\n" "$(basename "$cni_file")"
            CNI_CONFIG_FOUND=1
            K8S_DETECTED=1
        done

        cni_types=$(
            grep -hE '"type"[[:space:]]*:' "$cni_dir"/* 2>/dev/null \
                | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
                | sort -u \
                | tr '\n' ' ' \
                | sed 's/[[:space:]]*$//'
        )

        [ -n "$cni_types" ] && value "CNI plugin types" "$cni_types"
    fi
done

if [ "$CNI_CONFIG_FOUND" -eq 0 ]; then
    echo "  No conventional CNI config files visible."
fi

echo
echo "Kubernetes/CNI-looking interfaces:"
KNET_COUNT=0
if [ -d "$NETROOT" ]; then
    for iface_path in "$NETROOT"/*; do
        [ -e "$iface_path" ] || continue
        iface=$(basename "$iface_path")

        case "$iface" in
            cni*|flannel*|cilium*|cali*|ovn*|vxlan*|genev*|kube-ipvs0)
                state=$(firstline "$iface_path/operstate")
                mtu=$(firstline "$iface_path/mtu")
                printf "  %-20s state=%-8s mtu=%s\n" "$iface" "$state" "$mtu"
                KNET_COUNT=$((KNET_COUNT + 1))
                K8S_DETECTED=1
                ;;
        esac
    done
fi

if [ "$KNET_COUNT" -eq 0 ]; then
    echo "  None detected by common interface naming."
fi

if [ -r "$HOST_ROOT/proc/net/fib_trie" ]; then
    echo
    echo "Host-local IPv4 addresses visible in fib_trie:"
    awk '
        /32 host LOCAL/ {
            line = previous
            sub(/^.*\|--[[:space:]]*/, "", line)
            if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                print "  " line
        }
        { previous = $0 }
    ' "$HOST_ROOT/proc/net/fib_trie" 2>/dev/null | sort -u
fi

echo
echo "CSI / kubelet plugins:"
CSI_COUNT=0
if [ -d "$HOST_ROOT/var/lib/kubelet/plugins" ]; then
    for plugin_dir in "$HOST_ROOT/var/lib/kubelet/plugins"/*; do
        [ -d "$plugin_dir" ] || continue
        plugin=$(basename "$plugin_dir")

        case "$plugin" in
            kubernetes.io~*)
                continue
                ;;
        esac

        printf "  %s\n" "$plugin"
        CSI_COUNT=$((CSI_COUNT + 1))
    done
fi

if [ "$CSI_COUNT" -eq 0 ]; then
    echo "  No external kubelet/CSI plugin directories detected."
fi

if [ "$K8S_DETECTED" -eq 0 ]; then
    echo
    echo "No strong local Kubernetes indicators were detected."
fi


section "LIVE KUBERNETES SUMMARY (OPTIONAL)"

if command -v kubectl >/dev/null 2>&1; then
    if kubectl --request-timeout=3s get --raw=/version >/dev/null 2>&1; then
        value "kubectl" "connected"

        NODE_COUNT=$(kubectl --request-timeout=3s get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        NS_COUNT=$(kubectl --request-timeout=3s get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
        POD_COUNT=$(kubectl --request-timeout=3s get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

        value "Cluster nodes" "$NODE_COUNT"
        value "Namespaces" "$NS_COUNT"
        value "Pods" "$POD_COUNT"

        echo
        echo "Node summary:"
        kubectl --request-timeout=3s get nodes -o wide 2>/dev/null || true

        echo
        echo "Pod status counts:"
        kubectl --request-timeout=3s get pods -A --no-headers 2>/dev/null \
            | awk '{ count[$4]++ } END { for (state in count) printf "  %-18s %d\n", state, count[state] }' \
            | sort
    else
        echo "kubectl is installed, but no usable cluster context/API access is available."
    fi
else
    echo "kubectl is not installed in this container; local host-root inspection was used instead."
fi

echo
echo "======================================================================"
echo "END OF HOST MACHINE REPORT"
echo "======================================================================"
