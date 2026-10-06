#!/bin/sh
# PAC Labs Talos/Kubernetes diagnostic collector
# Produces a compact copy/paste-safe PACDIAG bundle on stdout.
# All progress and warnings go to stderr.
set -u

COLLECTOR_VERSION="1.1.0"
HOST_ROOT="${HOST_ROOT:-/host-root}"
SCAN_URL="${SCAN_URL:-https://raw.githubusercontent.com/pac-labs/tools/refs/heads/main/scan.sh}"
REDACT_NETWORK="${PACDIAG_REDACT_NETWORK:-0}"

say() { printf '%s\n' "$*" >&2; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
row() {
    first=1
    for field in "$@"; do
        if [ "$first" -eq 1 ]; then first=0; else printf '\t'; fi
        clean "$field"
    done
    printf '\n'
}
read1() { [ -r "$1" ] && head -n 1 "$1" 2>/dev/null || true; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t pacdiag)" || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

MACHINE="$TMP/machine.tsv"
K8S="$TMP/k8s.tsv"
SCAN="$TMP/scan.txt"
META="$TMP/meta.tsv"
: > "$MACHINE"; : > "$K8S"; : > "$SCAN"; : > "$META"

hostname_host=""
if [ -r "$HOST_ROOT/proc/sys/kernel/hostname" ]; then
    hostname_host="$(cat "$HOST_ROOT/proc/sys/kernel/hostname" 2>/dev/null)"
elif [ -r "$HOST_ROOT/etc/hostname" ]; then
    hostname_host="$(cat "$HOST_ROOT/etc/hostname" 2>/dev/null)"
else
    hostname_host="$(hostname 2>/dev/null || echo unknown)"
fi

row FORMAT 1 > "$META"
row collector_version "$COLLECTOR_VERSION" >> "$META"
row generated_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" >> "$META"
row hostname "$hostname_host" >> "$META"
row host_root "$HOST_ROOT" >> "$META"
row redact_network "$REDACT_NETWORK" >> "$META"

# Structured local host facts. This is intentionally conservative and read-only.
row SYSTEM hostname "$hostname_host" >> "$MACHINE"
if [ -r "$HOST_ROOT/etc/os-release" ]; then
    os_name="$(grep '^PRETTY_NAME=' "$HOST_ROOT/etc/os-release" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')"
    row SYSTEM os "$os_name" >> "$MACHINE"
    talos_ver="$(grep '^VERSION_ID=' "$HOST_ROOT/etc/os-release" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"v')"
    [ -n "$talos_ver" ] && row SYSTEM talos_version "$talos_ver" >> "$MACHINE"
fi
[ -r "$HOST_ROOT/proc/sys/kernel/osrelease" ] && row SYSTEM kernel "$(cat "$HOST_ROOT/proc/sys/kernel/osrelease")" >> "$MACHINE"

DMI="$HOST_ROOT/sys/class/dmi/id"
[ -r "$DMI/sys_vendor" ] && row SYSTEM manufacturer "$(cat "$DMI/sys_vendor")" >> "$MACHINE"
[ -r "$DMI/product_name" ] && row SYSTEM model "$(cat "$DMI/product_name")" >> "$MACHINE"
[ -r "$DMI/product_version" ] && row SYSTEM model_version "$(cat "$DMI/product_version")" >> "$MACHINE"

if [ -r "$HOST_ROOT/proc/cpuinfo" ]; then
    cpu_model="$(grep -m1 -E 'model name|Hardware|Processor' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
    cpu_logical="$(grep -c '^processor[[:space:]]*:' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null || echo 0)"
    sockets="$(awk -F: '/^physical id[[:space:]]*:/ {gsub(/[[:space:]]/,"",$2); seen[$2]=1} END {for (x in seen) n++; if(n) print n}' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null)"
    cores="$(awk -F: '/^physical id[[:space:]]*:/ {gsub(/[[:space:]]/,"",$2); p=$2} /^core id[[:space:]]*:/ {gsub(/[[:space:]]/,"",$2); if(p!="") seen[p":"$2]=1} END {for (x in seen) n++; if(n) print n}' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null)"
    flags="$(grep -m1 '^flags[[:space:]]*:' "$HOST_ROOT/proc/cpuinfo" 2>/dev/null | cut -d: -f2-)"
    virt=no
    printf '%s\n' "$flags" | grep -Eq '(^|[[:space:]])(vmx|svm)($|[[:space:]])' && virt=yes
    row CPU model "$cpu_model" >> "$MACHINE"
    row CPU logical "$cpu_logical" >> "$MACHINE"
    [ -n "$sockets" ] && row CPU sockets "$sockets" >> "$MACHINE"
    [ -n "$cores" ] && row CPU physical_cores "$cores" >> "$MACHINE"
    row VIRT hardware_virtualization "$virt" >> "$MACHINE"
fi

if [ -r "$HOST_ROOT/proc/meminfo" ]; then
    mem_kib="$(awk '/^MemTotal:/ {print $2}' "$HOST_ROOT/proc/meminfo")"
    avail_kib="$(awk '/^MemAvailable:/ {print $2}' "$HOST_ROOT/proc/meminfo")"
    huge_total="$(awk '/^HugePages_Total:/ {print $2}' "$HOST_ROOT/proc/meminfo")"
    huge_size="$(awk '/^Hugepagesize:/ {print $2}' "$HOST_ROOT/proc/meminfo")"
    row MEM total_kib "$mem_kib" >> "$MACHINE"
    row MEM available_kib "$avail_kib" >> "$MACHINE"
    row MEM hugepages_total "$huge_total" >> "$MACHINE"
    row MEM hugepage_kib "$huge_size" >> "$MACHINE"
fi

[ -e "$HOST_ROOT/dev/kvm" ] && row VIRT kvm_device yes >> "$MACHINE" || row VIRT kvm_device no >> "$MACHINE"
if [ -r "$HOST_ROOT/proc/modules" ]; then
    grep -Eq '^(kvm|kvm_intel|kvm_amd)[[:space:]]' "$HOST_ROOT/proc/modules" && row VIRT kvm_module yes >> "$MACHINE" || row VIRT kvm_module no >> "$MACHINE"
fi
if [ -d "$HOST_ROOT/sys/kernel/iommu_groups" ]; then
    iommu_groups="$(find "$HOST_ROOT/sys/kernel/iommu_groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    [ "${iommu_groups:-0}" -gt 0 ] 2>/dev/null && row VIRT iommu yes >> "$MACHINE" || row VIRT iommu no >> "$MACHINE"
    row VIRT iommu_groups "${iommu_groups:-0}" >> "$MACHINE"
fi

if [ -d "$HOST_ROOT/sys/block" ]; then
    for p in "$HOST_ROOT"/sys/block/*; do
        [ -e "$p" ] || continue
        n="$(basename "$p")"
        case "$n" in loop*|ram*|zram*|dm-*) continue ;; esac
        sectors="$(read1 "$p/size")"
        rotational="$(read1 "$p/queue/rotational")"
        model="$(read1 "$p/device/model")"
        serial="$(read1 "$p/device/serial")"
        removable="$(read1 "$p/removable")"
        vendor="$(read1 "$p/device/vendor")"
        revision="$(read1 "$p/device/rev")"
        wwid="$(read1 "$p/device/wwid")"
        [ -z "$wwid" ] && wwid="$(read1 "$p/wwid")"
        devno="$(read1 "$p/dev")"
        bus=""
        if [ -e "$p/device/subsystem" ]; then
            bus="$(basename "$(readlink -f "$p/device/subsystem" 2>/dev/null)")"
        fi
        case "$n" in nvme*) bus="nvme" ;; esac
        logical_bs="$(read1 "$p/queue/logical_block_size")"
        physical_bs="$(read1 "$p/queue/physical_block_size")"
        row DISK "$n" "${sectors:-0}" "${rotational:-unknown}" "$model" "$serial" "${removable:-0}" \
            "$vendor" "$revision" "$wwid" "$devno" "$bus" "$logical_bs" "$physical_bs" >> "$MACHINE"
    done
fi

# Partition inventory helps relate physical disks to filesystems without lsblk.
if [ -d "$HOST_ROOT/sys/class/block" ]; then
    for p in "$HOST_ROOT"/sys/class/block/*; do
        [ -r "$p/partition" ] || continue
        n="$(basename "$p")"
        parent="$(basename "$(dirname "$(readlink -f "$p" 2>/dev/null)")")"
        size="$(read1 "$p/size")"
        devno="$(read1 "$p/dev")"
        row PART "$n" "$parent" "${size:-0}" "$devno" >> "$MACHINE"
    done
fi

# Host filesystem usage. Pseudo filesystems and per-pod tmpfs/overlay mounts
# are intentionally omitted; the goal is server/storage capacity.
if [ -r "$HOST_ROOT/proc/1/mountinfo" ] && command -v df >/dev/null 2>&1; then
    while IFS= read -r mi; do
        set -- $mi
        [ "$#" -ge 10 ] || continue
        major_minor="$3"
        mountpoint="$5"
        shift 6
        while [ "$#" -gt 0 ] && [ "$1" != "-" ]; do shift; done
        [ "$#" -ge 3 ] || continue
        shift
        fstype="$1"
        source="$2"

        case "$fstype" in
            ext2|ext3|ext4|xfs|btrfs|vfat|f2fs|zfs|ceph|nfs|nfs4)
                ;;
            overlay)
                [ "$mountpoint" = "/" ] || continue
                ;;
            *)
                continue
                ;;
        esac

        host_path="$HOST_ROOT$mountpoint"
        [ "$mountpoint" = "/" ] && host_path="$HOST_ROOT"
        [ -e "$host_path" ] || continue

        stats="$(df -P -k "$host_path" 2>/dev/null | awk 'NR==2 {print $2 "|" $3 "|" $4 "|" $5}')"
        [ -n "$stats" ] || continue
        total_kib="$(printf '%s' "$stats" | cut -d'|' -f1)"
        used_kib="$(printf '%s' "$stats" | cut -d'|' -f2)"
        avail_kib="$(printf '%s' "$stats" | cut -d'|' -f3)"
        use_pct="$(printf '%s' "$stats" | cut -d'|' -f4 | tr -d '%')"
        row MOUNT "$major_minor" "$mountpoint" "$fstype" "$source" \
            "$total_kib" "$used_kib" "$avail_kib" "$use_pct" >> "$MACHINE"
    done < "$HOST_ROOT/proc/1/mountinfo"
fi

# A few high-value Kubernetes directories. This is cumulative disk usage,
# not a performance probe. Bound it when timeout(1) is available.
if command -v du >/dev/null 2>&1; then
    for d in /var/lib/kubelet /var/lib/containerd /var/lib/etcd; do
        hp="$HOST_ROOT$d"
        [ -d "$hp" ] || continue
        kib=""
        if command -v timeout >/dev/null 2>&1; then
            kib="$(timeout 20 du -sk "$hp" 2>/dev/null | awk 'NR==1 {print $1}')"
        fi
        [ -n "$kib" ] && row DIRUSE "$d" "$kib" >> "$MACHINE"
    done
fi

NETROOT="$HOST_ROOT/sys/class/net"
if [ -d "$NETROOT" ]; then
    for p in "$NETROOT"/*; do
        [ -e "$p" ] || continue
        n="$(basename "$p")"
        state="$(read1 "$p/operstate")"
        mtu="$(read1 "$p/mtu")"
        speed="$(read1 "$p/speed")"
        duplex="$(read1 "$p/duplex")"
        mac="$(read1 "$p/address")"
        carrier="$(read1 "$p/carrier")"
        driver=""
        vendor=""
        device=""
        numa=""
        sriov_total=""
        sriov_num=""
        bus_addr=""
        master=""
        if [ -e "$p/device" ]; then
            [ -L "$p/device/driver" ] && driver="$(basename "$(readlink "$p/device/driver" 2>/dev/null)")"
            vendor="$(read1 "$p/device/vendor")"
            device="$(read1 "$p/device/device")"
            numa="$(read1 "$p/device/numa_node")"
            sriov_total="$(read1 "$p/device/sriov_totalvfs")"
            sriov_num="$(read1 "$p/device/sriov_numvfs")"
            bus_addr="$(basename "$(readlink -f "$p/device" 2>/dev/null)")"
        fi
        [ -L "$p/master" ] && master="$(basename "$(readlink -f "$p/master" 2>/dev/null)")"
        rx_bytes="$(read1 "$p/statistics/rx_bytes")"
        tx_bytes="$(read1 "$p/statistics/tx_bytes")"
        rx_packets="$(read1 "$p/statistics/rx_packets")"
        tx_packets="$(read1 "$p/statistics/tx_packets")"
        rx_errors="$(read1 "$p/statistics/rx_errors")"
        tx_errors="$(read1 "$p/statistics/tx_errors")"
        rx_dropped="$(read1 "$p/statistics/rx_dropped")"
        tx_dropped="$(read1 "$p/statistics/tx_dropped")"
        carrier_changes="$(read1 "$p/carrier_changes")"
        if [ "$REDACT_NETWORK" = "1" ]; then mac="redacted"; fi
        row NET "$n" "$state" "$mac" "$mtu" "$speed" "$duplex" "$driver" "$vendor" "$device" "$numa" "$sriov_total" "$sriov_num" \
            "$carrier" "$bus_addr" "$master" "$rx_bytes" "$tx_bytes" "$rx_packets" "$tx_packets" "$rx_errors" "$tx_errors" "$rx_dropped" "$tx_dropped" "$carrier_changes" >> "$MACHINE"
        if [ -d "$p/bonding" ]; then
            mode="$(read1 "$p/bonding/mode")"
            slaves="$(read1 "$p/bonding/slaves")"
            lacp="$(read1 "$p/bonding/lacp_rate")"
            hash="$(read1 "$p/bonding/xmit_hash_policy")"
            row BOND "$n" "$mode" "$slaves" "$lacp" "$hash" >> "$MACHINE"
        fi
    done
fi

# VLAN relationships are available from procfs even when ip(8) is absent.
if [ -r "$HOST_ROOT/proc/net/vlan/config" ]; then
    awk -F'|' 'NR > 2 {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);
        if ($1 != "" && $2 != "" && $3 != "") print $1 "\t" $2 "\t" $3
    }' "$HOST_ROOT/proc/net/vlan/config" 2>/dev/null |
    while IFS="$(printf '\t')" read -r vlan_name vlan_id vlan_parent; do
        row VLAN "$vlan_name" "$vlan_id" "$vlan_parent"
    done >> "$MACHINE"
fi

if [ -r "$HOST_ROOT/proc/net/route" ]; then
    while IFS='\t' read -r iface destination gateway flags ref use metric mask mtu window irtt; do
        [ "$iface" = "Iface" ] && continue
        row ROUTE4 "$iface" "$destination" "$gateway" "$metric" "$mask" >> "$MACHINE"
    done < "$HOST_ROOT/proc/net/route"
fi

for cni_dir in "$HOST_ROOT/etc/cni/net.d" "$HOST_ROOT/var/lib/cni"; do
    [ -d "$cni_dir" ] && row K8SLOCAL cni_dir "${cni_dir#$HOST_ROOT}" >> "$MACHINE"
done
[ -d "$HOST_ROOT/var/lib/kubelet" ] && row K8SLOCAL kubelet_state present >> "$MACHINE"
[ -d "$HOST_ROOT/var/lib/etcd/member" ] && row K8SLOCAL etcd_data present >> "$MACHINE"
if [ -d "$HOST_ROOT/var/lib/kubelet/pods" ]; then
    poddirs="$(find "$HOST_ROOT/var/lib/kubelet/pods" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    row K8SLOCAL kubelet_pod_dirs "$poddirs" >> "$MACHINE"
fi

# Run the existing readable scanner as supporting evidence. Failure is captured, not fatal.
scan_source=""
if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --connect-timeout 5 --max-time 20 "$SCAN_URL" -o "$TMP/scan.sh" 2>/dev/null; then scan_source="$SCAN_URL"; fi
elif command -v wget >/dev/null 2>&1; then
    if wget -qO "$TMP/scan.sh" "$SCAN_URL" 2>/dev/null; then scan_source="$SCAN_URL"; fi
fi
if [ -z "$scan_source" ] && [ -r ./scan.sh ]; then cp ./scan.sh "$TMP/scan.sh"; scan_source="./scan.sh"; fi
if [ -r "$TMP/scan.sh" ]; then
    if sh -n "$TMP/scan.sh" 2>"$TMP/scan.syntax.err"; then
        HOST_ROOT="$HOST_ROOT" sh "$TMP/scan.sh" > "$SCAN" 2>&1
        scan_rc=$?
    else
        scan_rc=2
        { echo "scan.sh syntax validation failed"; cat "$TMP/scan.syntax.err"; } > "$SCAN"
    fi
else
    scan_rc=127
    echo "scan.sh unavailable; structured machine.tsv is still complete enough for the report." > "$SCAN"
fi
row scan_source "$scan_source" >> "$META"
row scan_exit_code "$scan_rc" >> "$META"

# Optional safe cluster summary. No Secrets, ConfigMaps, env values, kubeconfigs or certificates are collected.
if command -v kubectl >/dev/null 2>&1 && kubectl --request-timeout=4s get --raw=/version >/dev/null 2>&1; then
    row K8S connected yes >> "$K8S"
    server_ver="$(kubectl --request-timeout=4s version -o json 2>/dev/null | tr -d '\n' | sed -n 's/.*"serverVersion"[^{]*{[^}]*"gitVersion":"\([^"]*\)".*/\1/p')"
    [ -n "$server_ver" ] && row K8S server_version "$server_ver" >> "$K8S"

    kubectl --request-timeout=8s get nodes --no-headers \
      -o 'custom-columns=NAME:.metadata.name,CP:.metadata.labels.node-role\.kubernetes\.io/control-plane,VERSION:.status.nodeInfo.kubeletVersion,IP:.status.addresses[?(@.type=="InternalIP")].address,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion' 2>/dev/null \
      | while read -r name cp ver ip kernel runtime; do
            [ "$REDACT_NETWORK" = "1" ] && ip="redacted"
            role=worker; [ -n "$cp" ] && [ "$cp" != "<none>" ] && role=control-plane
            row NODE "$name" "$role" "$ver" "$ip" "$kernel" "$runtime"
        done >> "$K8S"

    kubectl --request-timeout=12s get pods -A --no-headers \
      -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,IMAGES:.spec.containers[*].image' 2>/dev/null \
      | while read -r ns name phase node images; do row POD "$ns" "$name" "$phase" "$node" "$images"; done >> "$K8S"

    for kind in deployments statefulsets daemonsets; do
        kubectl --request-timeout=10s get "$kind" -A --no-headers \
          -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.numberReady,DESIRED:.status.replicas,IMAGES:.spec.template.spec.containers[*].image' 2>/dev/null \
          | while read -r ns name ready desired images; do row WORKLOAD "$kind" "$ns" "$name" "${ready:-0}" "${desired:-0}" "$images"; done >> "$K8S"
    done

    kubectl --request-timeout=8s get storageclass --no-headers \
      -o 'custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode' 2>/dev/null \
      | while read -r name prov reclaim binding; do row STORAGECLASS "$name" "$prov" "$reclaim" "$binding"; done >> "$K8S"

    kubectl --request-timeout=8s get pvc -A --no-headers \
      -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,SIZE:.status.capacity.storage' 2>/dev/null \
      | while read -r ns name status sc size; do row PVC "$ns" "$name" "$status" "$sc" "$size"; done >> "$K8S"

    kubectl --request-timeout=8s get crd -o name 2>/dev/null \
      | grep -Ei '(ceph|rook|openstack|nova|neutron|cinder|keystone|glance)' \
      | while read -r crd; do row CRD "$crd"; done >> "$K8S"

    # Rook/Ceph summaries when those CRDs are installed.
    kubectl --request-timeout=8s get cephcluster -A --no-headers \
      -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,STATE:.status.state,HEALTH:.status.ceph.health,CURRENT:.status.ceph.version.version,TARGET:.spec.cephVersion.image,TOTAL:.status.ceph.capacity.bytesTotal,USED:.status.ceph.capacity.bytesUsed,AVAILABLE:.status.ceph.capacity.bytesAvailable' 2>/dev/null \
      | while read -r ns name phase state health current target total used available; do row CEPHCLUSTER "$ns" "$name" "$phase" "$state" "$health" "$current" "$target" "$total" "$used" "$available"; done >> "$K8S"

    for kind in cephblockpool cephfilesystem cephobjectstore; do
        kubectl --request-timeout=8s get "$kind" -A --no-headers \
          -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
          | while read -r ns name; do row CEPHRESOURCE "$kind" "$ns" "$name"; done >> "$K8S"
    done
else
    row K8S connected no >> "$K8S"
fi

# Package a tiny tar.gz archive and base64 it for copy/paste transport.
ARCHIVE="$TMP/pacdiag-${hostname_host:-node}.tar.gz"
if tar -czf "$ARCHIVE" -C "$TMP" meta.tsv machine.tsv k8s.tsv scan.txt 2>/dev/null; then
    :
else
    say "Unable to create tar.gz archive"
    exit 2
fi

say "PACDIAG collected for ${hostname_host:-unknown}; copy stdout between the markers."
printf '%s\n' '-----BEGIN PACDIAG V1-----'
base64 "$ARCHIVE"
printf '%s\n' '-----END PACDIAG V1-----'
