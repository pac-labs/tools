#!/usr/bin/env python3
"""PACDIAG environment report generator.

Accepts any number of PACDIAG copy/paste bundles and/or legacy scan.sh outputs,
builds an environment model, evaluates Ceph/OpenStack production readiness, and
writes HTML, PDF (when reportlab is installed), Markdown and JSON reports.
"""
from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import html
import io
import json
import os
import re
import sys
import tarfile
import textwrap
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

TOOL_VERSION = "1.0.0"
BASELINE_DATE = "2026-10-06"
FALLBACK_CURRENT = {
    "talos": "1.14.1",
    "rook": "1.20.8",
    "ceph": "20.2.4",
    "openstack": "2026.2 Hibiscus",
}
SOURCES = {
    "talos": "https://github.com/siderolabs/talos/releases/latest",
    "rook": "https://github.com/rook/rook/releases/latest",
    "ceph": "https://docs.ceph.com/en/latest/releases/",
    "ceph_hw": "https://docs.ceph.com/en/tentacle/start/hardware-recommendations/",
    "ceph_net": "https://docs.ceph.com/en/latest/start/hardware-networks/",
    "openstack": "https://releases.openstack.org/",
}

BEGIN = "-----BEGIN PACDIAG V1-----"
END = "-----END PACDIAG V1-----"


def nfloat(v: Any, default: float = 0.0) -> float:
    try:
        return float(str(v).strip())
    except Exception:
        return default


def nint(v: Any, default: int = 0) -> int:
    try:
        return int(float(str(v).strip()))
    except Exception:
        return default


def ver_tuple(v: str) -> tuple[int, ...]:
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:4])


def fmt_gib_from_kib(kib: Any) -> str:
    return f"{nfloat(kib) / 1024 / 1024:.1f} GiB"


def fmt_disk_gib(sectors: Any) -> str:
    return f"{nfloat(sectors) * 512 / 1024**3:.1f} GiB"


def safe(s: Any) -> str:
    return html.escape(str(s if s is not None else ""))


@dataclasses.dataclass
class Disk:
    name: str
    sectors: int = 0
    rotational: str = "unknown"
    model: str = ""
    serial: str = ""
    removable: str = "0"

    @property
    def gib(self) -> float:
        return self.sectors * 512 / 1024**3


@dataclasses.dataclass
class NetIf:
    name: str
    state: str = ""
    mac: str = ""
    mtu: int = 0
    speed_mbps: int = 0
    duplex: str = ""
    driver: str = ""
    vendor: str = ""
    device: str = ""
    numa: str = ""
    sriov_total: int = 0
    sriov_num: int = 0

    @property
    def physical(self) -> bool:
        if self.name == "lo":
            return False
        virtual_prefixes = ("veth", "cni", "flannel", "cali", "cilium", "tun", "sit", "ip6tnl", "dummy", "teql")
        if self.name.startswith(virtual_prefixes):
            return False
        if "." in self.name and not self.driver:
            return False
        if self.name.startswith("bond"):
            return False
        return bool(self.driver or self.vendor or self.device)


@dataclasses.dataclass
class Bond:
    name: str
    mode: str = ""
    slaves: str = ""
    lacp_rate: str = ""
    hash_policy: str = ""


@dataclasses.dataclass
class Node:
    name: str = "unknown"
    os: str = ""
    talos_version: str = ""
    kernel: str = ""
    manufacturer: str = ""
    model: str = ""
    model_version: str = ""
    cpu_model: str = ""
    logical_cpus: int = 0
    sockets: int = 0
    physical_cores: int = 0
    mem_total_kib: int = 0
    mem_available_kib: int = 0
    hugepages_total: int = 0
    hugepage_kib: int = 0
    hw_virt: str = "unknown"
    kvm_device: str = "unknown"
    kvm_module: str = "unknown"
    iommu: str = "unknown"
    iommu_groups: int = 0
    disks: list[Disk] = dataclasses.field(default_factory=list)
    nets: list[NetIf] = dataclasses.field(default_factory=list)
    bonds: list[Bond] = dataclasses.field(default_factory=list)
    routes: list[list[str]] = dataclasses.field(default_factory=list)
    kubelet_state: str = ""
    etcd_data: str = ""
    kubelet_pod_dirs: int = 0
    source: str = ""

    @property
    def mem_gib(self) -> float:
        return self.mem_total_kib / 1024 / 1024

    @property
    def max_physical_link_mbps(self) -> int:
        return max([n.speed_mbps for n in self.nets if n.physical and n.state == "up"] or [0])

    @property
    def physical_nics(self) -> list[NetIf]:
        return [n for n in self.nets if n.physical]

    @property
    def osd_candidate_count(self) -> int:
        # Conservative heuristic: assume one whole physical disk is the OS disk.
        return max(0, len([d for d in self.disks if d.removable != "1"]) - 1)


@dataclasses.dataclass
class ClusterView:
    k8s_connected: bool = False
    k8s_server_version: str = ""
    nodes: dict[str, dict[str, str]] = dataclasses.field(default_factory=dict)
    pods: dict[tuple[str, str], dict[str, str]] = dataclasses.field(default_factory=dict)
    workloads: dict[tuple[str, str, str], dict[str, str]] = dataclasses.field(default_factory=dict)
    storageclasses: dict[str, dict[str, str]] = dataclasses.field(default_factory=dict)
    pvcs: dict[tuple[str, str], dict[str, str]] = dataclasses.field(default_factory=dict)
    crds: set[str] = dataclasses.field(default_factory=set)
    cephclusters: dict[tuple[str, str], dict[str, str]] = dataclasses.field(default_factory=dict)
    cephresources: set[tuple[str, str, str]] = dataclasses.field(default_factory=set)


@dataclasses.dataclass
class Check:
    status: str  # PASS/WARN/UNKNOWN/BLOCKER
    title: str
    detail: str
    recommendation: str = ""
    weight: int = 10
    critical: bool = False

    @property
    def score_factor(self) -> float:
        return {"PASS": 1.0, "WARN": 0.65, "UNKNOWN": 0.4, "BLOCKER": 0.0}.get(self.status, 0.4)


@dataclasses.dataclass
class Assessment:
    name: str
    checks: list[Check]
    hardware_summary: str
    production_summary: str

    @property
    def score(self) -> int:
        total = sum(c.weight for c in self.checks) or 1
        got = sum(c.weight * c.score_factor for c in self.checks)
        return round(100 * got / total)

    @property
    def blockers(self) -> list[Check]:
        return [c for c in self.checks if c.status == "BLOCKER"]

    @property
    def critical_unknowns(self) -> list[Check]:
        return [c for c in self.checks if c.status == "UNKNOWN" and c.critical]

    @property
    def verdict(self) -> str:
        if self.blockers:
            return "NOT PRODUCTION READY"
        if self.critical_unknowns:
            return "CONDITIONALLY CAPABLE - VALIDATION REQUIRED"
        if any(c.status == "WARN" for c in self.checks):
            return "PRODUCTION-CAPABLE WITH RISKS"
        return "PRODUCTION-CAPABLE"


@dataclasses.dataclass
class Environment:
    nodes: list[Node] = dataclasses.field(default_factory=list)
    cluster: ClusterView = dataclasses.field(default_factory=ClusterView)
    bundle_meta: list[dict[str, str]] = dataclasses.field(default_factory=list)
    parse_warnings: list[str] = dataclasses.field(default_factory=list)


# ----------------------------- Input parsing -----------------------------

def parse_tsv(text: str) -> list[list[str]]:
    out = []
    for line in text.splitlines():
        if not line.strip():
            continue
        out.append(line.rstrip("\n").split("\t"))
    return out


def parse_bundle_payload(payload: bytes, env: Environment, source: str) -> None:
    try:
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as tf:
            files: dict[str, str] = {}
            for name in ("meta.tsv", "machine.tsv", "k8s.tsv", "scan.txt"):
                try:
                    f = tf.extractfile(name)
                    if f:
                        files[name] = f.read().decode("utf-8", errors="replace")
                except KeyError:
                    pass
    except Exception as e:
        env.parse_warnings.append(f"{source}: unable to unpack PACDIAG bundle: {e}")
        return

    meta = {}
    for row in parse_tsv(files.get("meta.tsv", "")):
        if len(row) >= 2:
            meta[row[0]] = row[1]
    meta["source"] = source
    env.bundle_meta.append(meta)

    node = Node(name=meta.get("hostname", "unknown"), source=source)
    for row in parse_tsv(files.get("machine.tsv", "")):
        if not row:
            continue
        typ = row[0]
        if typ == "SYSTEM" and len(row) >= 3:
            key, val = row[1], row[2]
            if key == "hostname": node.name = val
            elif key == "os": node.os = val
            elif key == "talos_version": node.talos_version = val.lstrip("v")
            elif key == "kernel": node.kernel = val
            elif key == "manufacturer": node.manufacturer = val
            elif key == "model": node.model = val
            elif key == "model_version": node.model_version = val
        elif typ == "CPU" and len(row) >= 3:
            key, val = row[1], row[2]
            if key == "model": node.cpu_model = val
            elif key == "logical": node.logical_cpus = nint(val)
            elif key == "sockets": node.sockets = nint(val)
            elif key == "physical_cores": node.physical_cores = nint(val)
        elif typ == "MEM" and len(row) >= 3:
            key, val = row[1], row[2]
            if key == "total_kib": node.mem_total_kib = nint(val)
            elif key == "available_kib": node.mem_available_kib = nint(val)
            elif key == "hugepages_total": node.hugepages_total = nint(val)
            elif key == "hugepage_kib": node.hugepage_kib = nint(val)
        elif typ == "VIRT" and len(row) >= 3:
            key, val = row[1], row[2]
            if key == "hardware_virtualization": node.hw_virt = val
            elif key == "kvm_device": node.kvm_device = val
            elif key == "kvm_module": node.kvm_module = val
            elif key == "iommu": node.iommu = val
            elif key == "iommu_groups": node.iommu_groups = nint(val)
        elif typ == "DISK" and len(row) >= 7:
            node.disks.append(Disk(row[1], nint(row[2]), row[3], row[4], row[5], row[6]))
        elif typ == "NET" and len(row) >= 13:
            node.nets.append(NetIf(
                name=row[1], state=row[2], mac=row[3], mtu=nint(row[4]), speed_mbps=max(0, nint(row[5])),
                duplex=row[6], driver=row[7], vendor=row[8], device=row[9], numa=row[10],
                sriov_total=nint(row[11]), sriov_num=nint(row[12])
            ))
        elif typ == "BOND" and len(row) >= 6:
            node.bonds.append(Bond(row[1], row[2], row[3], row[4], row[5]))
        elif typ == "ROUTE4":
            node.routes.append(row[1:])
        elif typ == "K8SLOCAL" and len(row) >= 3:
            if row[1] == "kubelet_state": node.kubelet_state = row[2]
            elif row[1] == "etcd_data": node.etcd_data = row[2]
            elif row[1] == "kubelet_pod_dirs": node.kubelet_pod_dirs = nint(row[2])

    # If the structured payload predates a field, fill safe gaps from readable scan text.
    scan = files.get("scan.txt", "")
    if scan and (not node.os or not node.cpu_model or not node.mem_total_kib):
        legacy = parse_legacy_scan(scan, source + ":scan.txt")
        merge_node(node, legacy)
    env.nodes.append(node)
    merge_k8s(env.cluster, files.get("k8s.tsv", ""))


def merge_node(dst: Node, src: Node) -> None:
    for f in dataclasses.fields(Node):
        name = f.name
        if name in {"disks", "nets", "bonds", "routes"}:
            if not getattr(dst, name) and getattr(src, name):
                setattr(dst, name, getattr(src, name))
        else:
            cur = getattr(dst, name)
            if cur in ("", 0, "unknown", None) and getattr(src, name) not in ("", 0, "unknown", None):
                setattr(dst, name, getattr(src, name))


def merge_k8s(c: ClusterView, text: str) -> None:
    for row in parse_tsv(text):
        if not row:
            continue
        typ = row[0]
        if typ == "K8S" and len(row) >= 3:
            if row[1] == "connected": c.k8s_connected = c.k8s_connected or row[2] == "yes"
            elif row[1] == "server_version" and not c.k8s_server_version: c.k8s_server_version = row[2]
        elif typ == "NODE" and len(row) >= 7:
            c.nodes[row[1]] = {"role": row[2], "version": row[3], "ip": row[4], "kernel": row[5], "runtime": row[6]}
        elif typ == "POD" and len(row) >= 6:
            c.pods[(row[1], row[2])] = {"phase": row[3], "node": row[4], "images": row[5]}
        elif typ == "WORKLOAD" and len(row) >= 7:
            c.workloads[(row[1], row[2], row[3])] = {"ready": row[4], "desired": row[5], "images": row[6]}
        elif typ == "STORAGECLASS" and len(row) >= 5:
            c.storageclasses[row[1]] = {"provisioner": row[2], "reclaim": row[3], "binding": row[4]}
        elif typ == "PVC" and len(row) >= 6:
            c.pvcs[(row[1], row[2])] = {"status": row[3], "storageclass": row[4], "size": row[5]}
        elif typ == "CRD" and len(row) >= 2:
            c.crds.add(row[1])
        elif typ == "CEPHCLUSTER" and len(row) >= 8:
            c.cephclusters[(row[1], row[2])] = {"phase": row[3], "state": row[4], "health": row[5], "current": row[6], "target": row[7]}
        elif typ == "CEPHRESOURCE" and len(row) >= 4:
            c.cephresources.add((row[1], row[2], row[3]))


def parse_legacy_scan(text: str, source: str) -> Node:
    node = Node(source=source)
    def m(pattern: str, flags=0) -> str:
        mm = re.search(pattern, text, flags)
        return mm.group(1).strip() if mm else ""

    node.os = m(r"^OS:\s+(.+)$", re.M)
    node.name = m(r"^Hostname:\s+(.+)$", re.M) or Path(source).stem
    node.kernel = m(r"^Kernel:\s+(.+)$", re.M)
    node.manufacturer = m(r"^Manufacturer:\s+(.+)$", re.M)
    node.model = m(r"^Model:\s+(.+)$", re.M)
    tv = re.search(r"Talos\s*\(v?([0-9.]+)\)", node.os, re.I)
    if tv: node.talos_version = tv.group(1)
    node.cpu_model = m(r"^CPU model:\s+(.+)$", re.M)
    node.logical_cpus = nint(m(r"^Logical CPUs:\s+(\d+)", re.M))
    mem = m(r"^Memory total:\s+([0-9.]+)\s+GiB", re.M)
    node.mem_total_kib = int(nfloat(mem) * 1024 * 1024)
    avail = m(r"^Memory available:\s+([0-9.]+)\s+GiB", re.M)
    node.mem_available_kib = int(nfloat(avail) * 1024 * 1024)
    node.hugepages_total = nint(m(r"^HugePages_Total:\s+(\d+)", re.M))
    node.hugepage_kib = nint(m(r"^Hugepagesize:\s+(\d+)\s+kB", re.M))

    # Storage table from old scan output.
    storage = re.search(r"STORAGE DEVICES\s*\n=+\s*\n(.*?)(?:\n\s*=+\s*\nNETWORK INTERFACES|\Z)", text, re.S)
    if storage:
        for line in storage.group(1).splitlines():
            mm = re.match(r"\s*(\S+)\s+([0-9.]+)\s+GiB\s+(\S+)\s*(.*)$", line)
            if mm:
                gib = nfloat(mm.group(2)); rot = "0" if "SSD" in mm.group(3).upper() or "NVME" in mm.group(3).upper() else "1"
                sectors = int(gib * 1024**3 / 512)
                node.disks.append(Disk(mm.group(1), sectors, rot, mm.group(4).strip()))

    # Interface blocks.
    for block in re.finditer(r"^---\s+([^\s]+)\s+---\s*$\n(.*?)(?=^---\s+|^=+\s*$|\Z)", text, re.M | re.S):
        name, body = block.group(1), block.group(2)
        def bm(p):
            x = re.search(p, body, re.M)
            return x.group(1).strip() if x else ""
        speed_txt = bm(r"^Current speed:\s+([^\n]+)")
        speed = nint(re.search(r"(\d+)", speed_txt).group(1)) if re.search(r"(\d+)", speed_txt) else 0
        node.nets.append(NetIf(
            name=name, state=bm(r"^State:\s+([^\n]*)"), mac=bm(r"^MAC:\s+([^\n]*)"), mtu=nint(bm(r"^MTU:\s+(\d+)")),
            speed_mbps=speed, duplex=bm(r"^Duplex:\s+([^\n]*)"), driver=bm(r"^Driver:\s+([^\n]*)"),
            vendor=bm(r"^PCI vendor:\s+([^\n]*)"), device=bm(r"^PCI device:\s+([^\n]*)"), numa=bm(r"^NUMA node:\s+([^\n]*)"),
            sriov_total=nint(bm(r"^SR-IOV max VFs:\s+(\d+)")), sriov_num=nint(bm(r"^SR-IOV enabled VFs:\s+(\d+)"))
        ))
        mode = bm(r"/bonding/mode:([^\n]+)")
        slaves = bm(r"/bonding/slaves:([^\n]+)")
        if mode or slaves:
            node.bonds.append(Bond(name, mode, slaves))

    # Newer scan additions, if present.
    hv = m(r"^Hardware virtualization:\s+(.+)$", re.M)
    if hv: node.hw_virt = hv.lower()
    kd = m(r"^KVM device:\s+(.+)$", re.M)
    if kd: node.kvm_device = "yes" if kd.lower() in {"yes", "present", "available"} else kd.lower()
    km = m(r"^KVM modules?:\s+(.+)$", re.M)
    if km: node.kvm_module = "yes" if "present" in km.lower() or "yes" in km.lower() else km.lower()
    io_m = m(r"^IOMMU:\s+(.+)$", re.M)
    if io_m: node.iommu = "yes" if "enabled" in io_m.lower() or "yes" in io_m.lower() else io_m.lower()
    node.sockets = nint(m(r"^CPU sockets:\s+(\d+)", re.M))
    node.physical_cores = nint(m(r"^Physical cores:\s+(\d+)", re.M))
    if "Kubelet state" in text or "KUBERNETES / TALOS LOCAL NODE" in text:
        node.kubelet_state = "present"
    return node


def extract_inputs(text: str, source: str, env: Environment) -> None:
    found = False
    pos = 0
    while True:
        b = text.find(BEGIN, pos)
        if b < 0: break
        e = text.find(END, b)
        if e < 0:
            env.parse_warnings.append(f"{source}: PACDIAG BEGIN marker without END marker")
            break
        b64 = text[b + len(BEGIN):e]
        try:
            payload = base64.b64decode(re.sub(r"\s+", "", b64), validate=False)
            parse_bundle_payload(payload, env, source)
            found = True
        except Exception as ex:
            env.parse_warnings.append(f"{source}: cannot decode PACDIAG block: {ex}")
        pos = e + len(END)
    if not found and "HOST MACHINE REPORT" in text:
        env.nodes.append(parse_legacy_scan(text, source))
        found = True
    if not found and text.strip():
        env.parse_warnings.append(f"{source}: no PACDIAG bundle or legacy HOST MACHINE REPORT found")


def collect_paths(paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            for child in sorted(p.rglob("*")):
                if child.is_file() and child.suffix.lower() in {".txt", ".log", ".pacdiag", ".diag", ".out"}:
                    out.append(child)
        elif p.is_file():
            out.append(p)
    return out


# ----------------------------- Detection -----------------------------

def detect_components(env: Environment) -> dict[str, list[str]]:
    texts = []
    for (ns, name), pod in env.cluster.pods.items():
        texts.append(f"{ns} {name} {pod.get('images','')}")
    for (kind, ns, name), w in env.cluster.workloads.items():
        texts.append(f"{kind} {ns} {name} {w.get('images','')}")
    alltxt = "\n".join(texts).lower()

    ceph = []
    for label, keys in {
        "Rook operator": ["rook-ceph-operator"],
        "Ceph MON": ["rook-ceph-mon", "ceph-mon"],
        "Ceph MGR": ["rook-ceph-mgr", "ceph-mgr"],
        "Ceph OSD": ["rook-ceph-osd", "ceph-osd"],
        "Ceph CSI": ["csi-rbd", "csi-cephfs", "rook-ceph-csi"],
        "Ceph RGW": ["rook-ceph-rgw", "ceph-rgw"],
        "Ceph MDS": ["rook-ceph-mds", "ceph-mds"],
    }.items():
        if any(k in alltxt for k in keys): ceph.append(label)
    if env.cluster.cephclusters and "Rook operator" not in ceph:
        ceph.append("CephCluster CR detected")

    openstack = []
    for svc in ["keystone", "nova", "neutron", "glance", "cinder", "placement", "horizon", "heat", "octavia", "barbican", "ironic", "manila", "swift"]:
        if svc in alltxt: openstack.append(svc.capitalize())
    for dep in ["rabbitmq", "mariadb", "mysql", "memcached"]:
        if dep in alltxt: openstack.append(dep.capitalize())

    cni = []
    local_names = " ".join(n.name for node in env.nodes for n in node.nets).lower() + " " + alltxt
    for name in ["flannel", "cilium", "calico", "ovn", "canal"]:
        if name in local_names: cni.append(name)

    return {"ceph": sorted(set(ceph)), "openstack": sorted(set(openstack)), "cni": sorted(set(cni))}


def detect_versions(env: Environment) -> dict[str, str]:
    out: dict[str, str] = {}
    if env.cluster.k8s_server_version:
        out["kubernetes"] = env.cluster.k8s_server_version
    talos = sorted({n.talos_version for n in env.nodes if n.talos_version}, key=ver_tuple)
    if talos: out["talos"] = ", ".join(talos)

    blob = " ".join(
        [p.get("images", "") for p in env.cluster.pods.values()] +
        [w.get("images", "") for w in env.cluster.workloads.values()] +
        [c.get("current", "") + " " + c.get("target", "") for c in env.cluster.cephclusters.values()]
    )
    m = re.search(r"(?:ceph[:@/]|ceph.*?)(?:v)?(20\.\d+\.\d+|19\.\d+\.\d+|18\.\d+\.\d+)", blob, re.I)
    if m: out["ceph"] = m.group(1)
    m = re.search(r"rook(?:/ceph)?[:@].*?v?(1\.\d+\.\d+)", blob, re.I)
    if not m: m = re.search(r"rook.*?v?(1\.\d+\.\d+)", blob, re.I)
    if m: out["rook"] = m.group(1)
    m = re.search(r"\b(202[3-9]\.[12])\b", blob)
    if m: out["openstack"] = m.group(1)
    return out


# ----------------------------- Current versions -----------------------------

def fetch_url(url: str, timeout: int = 5) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": f"PACDIAG/{TOOL_VERSION}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def current_versions(offline: bool) -> tuple[dict[str, str], dict[str, str]]:
    cur = dict(FALLBACK_CURRENT)
    provenance = {k: f"fallback baseline {BASELINE_DATE}" for k in cur}
    if offline:
        return cur, provenance
    for key, repo in [("talos", "siderolabs/talos"), ("rook", "rook/rook")]:
        try:
            data = json.loads(fetch_url(f"https://api.github.com/repos/{repo}/releases/latest"))
            tag = str(data.get("tag_name", "")).lstrip("v")
            if tag:
                cur[key] = tag
                provenance[key] = "live GitHub release API"
        except Exception:
            pass
    try:
        page = re.sub(r"<[^>]+>", " ", fetch_url(SOURCES["ceph"]))
        mm = re.search(r"Tentacle\s+2025.*?(20\.\d+\.\d+)", re.sub(r"\s+", " ", page), re.I)
        if not mm:
            mm = re.search(r"Tentacle.*?(20\.\d+\.\d+)", re.sub(r"\s+", " ", page), re.I)
        if mm:
            cur["ceph"] = mm.group(1); provenance["ceph"] = "live Ceph releases page"
    except Exception:
        pass
    # OpenStack fallback is intentional: release pages do not expose a compact latest API.
    return cur, provenance


# ----------------------------- Assessments -----------------------------

def talos_lifecycle_check(env: Environment, current: str) -> Check:
    vers = [n.talos_version for n in env.nodes if n.talos_version]
    if not vers:
        return Check("UNKNOWN", "Talos lifecycle", "Talos version could not be determined.", "Collect /etc/os-release from each node.", 12, True)
    cur = ver_tuple(current)
    worst = min((ver_tuple(v), v) for v in vers)
    wtuple, wver = worst
    if len(cur) >= 2 and len(wtuple) >= 2:
        gap = (cur[0] - wtuple[0]) * 100 + (cur[1] - wtuple[1])
        if gap >= 2:
            return Check("BLOCKER", "Talos lifecycle", f"Oldest node is Talos {wver}; current is {current}. It is {gap} minor release lines behind and outside the normal latest-two-minors security window.", "Upgrade Talos before calling the platform production-ready.", 12, True)
        if gap == 1:
            return Check("PASS", "Talos lifecycle", f"Oldest node is Talos {wver}; current is {current}. This is within the normal latest-two-minors window.", weight=12)
    if wtuple < cur:
        return Check("WARN", "Talos lifecycle", f"Nodes run {', '.join(sorted(set(vers)))} while current is {current}.", "Plan a patch upgrade.", 12)
    return Check("PASS", "Talos lifecycle", f"Nodes are current at Talos {wver}.", weight=12)


def assess_ceph(env: Environment, cur: dict[str, str], detected: dict[str, str]) -> Assessment:
    checks: list[Check] = []
    nodes = env.nodes
    n = len(nodes)
    checks.append(Check("PASS" if n >= 3 else "BLOCKER", "Minimum host count", f"{n} scanned host(s). Replicated Ceph production storage normally needs at least three independent hosts.", "Provide at least three storage hosts." if n < 3 else "", 12, True))

    osd_nodes = [x for x in nodes if x.osd_candidate_count > 0]
    candidates = sum(x.osd_candidate_count for x in nodes)
    if len(osd_nodes) >= 3 and candidates >= 3:
        checks.append(Check("PASS", "Dedicated OSD candidates", f"Conservative heuristic finds {candidates} non-OS disk candidate(s) across {len(osd_nodes)} hosts.", weight=16))
    else:
        checks.append(Check("BLOCKER", "Dedicated OSD candidates", f"Only {candidates} conservative OSD candidate(s) across {len(osd_nodes)} host(s). The heuristic reserves one physical disk per node for the OS.", "Provide dedicated raw OSD devices on at least three hosts, separate from the Talos system disk.", 16, True))

    storage_basis = osd_nodes or nodes
    if storage_basis:
        low_mem = [x for x in storage_basis if x.mem_gib < 16]
        if low_mem:
            checks.append(Check("WARN", "Memory headroom", f"{len(low_mem)} storage candidate node(s) have under 16 GiB RAM. Ceph sizing is daemon/OSD dependent; 4+ GiB per OSD daemon is a common baseline.", "Increase memory or reduce OSD density.", 8))
        else:
            checks.append(Check("PASS", "Memory headroom", f"All storage candidate nodes have at least 16 GiB; minimum observed is {min(x.mem_gib for x in storage_basis):.1f} GiB.", weight=8))

    links = [x.max_physical_link_mbps for x in storage_basis if x.max_physical_link_mbps]
    if not links:
        checks.append(Check("UNKNOWN", "Ceph network bandwidth", "No active physical link speed could be established on the storage candidates.", "Collect sysfs NIC speed or ethtool data.", 12, True))
    elif min(links) < 10000:
        checks.append(Check("BLOCKER", "Ceph network bandwidth", f"Slowest storage-node active physical link is {min(links)/1000:.1f} Gb/s; Ceph guidance calls for at least 10 Gb/s between hosts and clients.", "Provide >=10 Gb/s; 25 Gb/s is preferred for substantial workloads.", 12, True))
    elif min(links) < 25000:
        checks.append(Check("PASS", "Ceph network bandwidth", f"All observed storage-node active links are at least 10 Gb/s (minimum {min(links)/1000:.1f} Gb/s). This meets the baseline; 25 Gb/s is preferred for substantial workloads.", weight=12))
    else:
        checks.append(Check("PASS", "Ceph network bandwidth", f"All observed storage-node active links are at least 25 Gb/s (minimum {min(links)/1000:.1f} Gb/s).", weight=12))

    lacp_nodes = [x for x in storage_basis if any("802.3ad" in b.mode or b.mode.strip().startswith("802.3ad") for b in x.bonds)]
    if len(lacp_nodes) >= min(3, len(storage_basis)) and storage_basis:
        checks.append(Check("PASS", "Host link bonding", f"802.3ad/LACP bonding is visible on {len(lacp_nodes)} storage candidate node(s).", "Confirm the bond members terminate on separate switches.", 7))
    else:
        checks.append(Check("WARN", "Host link bonding", f"802.3ad/LACP is visible on {len(lacp_nodes)} storage candidate node(s).", "Ceph strongly recommends active/active bonded links across separate switches.", 7))

    checks.append(talos_lifecycle_check(env, cur["talos"]))

    cp = [v for v in env.cluster.nodes.values() if v.get("role") == "control-plane"]
    if env.cluster.k8s_connected:
        checks.append(Check("PASS" if len(cp) >= 3 else "BLOCKER", "Kubernetes control-plane HA", f"Cluster summary shows {len(cp)} control-plane node(s).", "Use at least three control-plane nodes for a production Rook/Ceph control plane." if len(cp) < 3 else "", 9, True))
    else:
        checks.append(Check("UNKNOWN", "Kubernetes control-plane HA", "No authenticated kubectl cluster summary was captured.", "Capture cluster-level node roles or provide topology metadata.", 9, True))

    if env.cluster.cephclusters:
        unhealthy = []
        for (ns, name), c in env.cluster.cephclusters.items():
            if str(c.get("health", "")).upper() not in {"HEALTH_OK", "OK"}:
                unhealthy.append(f"{ns}/{name}={c.get('health') or c.get('phase')}")
        checks.append(Check("PASS" if not unhealthy else "BLOCKER", "Existing Ceph health", "All detected CephCluster resources report healthy." if not unhealthy else "Unhealthy CephCluster resources: " + ", ".join(unhealthy), "Resolve Ceph health before production use." if unhealthy else "", 12, True))
    else:
        checks.append(Check("UNKNOWN", "Existing Ceph health", "No CephCluster resource was detected; this may be a hardware-only assessment.", weight=5))

    dv = detected.get("ceph", "")
    if dv:
        if ver_tuple(dv) >= (19, 2, 6):
            checks.append(Check("PASS", "Ceph release", f"Detected Ceph {dv}; current Tentacle is {cur['ceph']}. The detected branch is still in the actively maintained generation as of the report baseline.", weight=7))
        elif ver_tuple(dv) >= (19, 0, 0):
            checks.append(Check("WARN", "Ceph release", f"Detected Ceph {dv}; current is {cur['ceph']}.", "Patch to a currently supported release.", 7))
        else:
            checks.append(Check("BLOCKER", "Ceph release", f"Detected Ceph {dv}; current is {cur['ceph']} and older generations are no longer maintained.", "Upgrade Ceph before production use.", 7, True))

    checks.append(Check("UNKNOWN", "Failure-domain independence", "A host scan cannot prove separate racks, PDUs, power feeds, switch failure domains or BMC isolation.", "Document rack/power/switch placement and validate that replica failure domains are genuinely independent.", 8, True))
    checks.append(Check("UNKNOWN", "Drive PLP and media endurance", "The scan can identify devices but cannot reliably prove enterprise power-loss protection, endurance class, firmware health or SMART history.", "Validate OSD media class, PLP, endurance and SMART/firmware health.", 6, True))
    checks.append(Check("UNKNOWN", "Backup and recovery test", "Host inventory cannot prove backups, restore testing or disaster recovery procedures.", "Perform and document restore/recovery tests before production sign-off.", 6, True))

    hw_blockers = [c for c in checks if c.status == "BLOCKER" and c.title in {"Minimum host count", "Dedicated OSD candidates", "Ceph network bandwidth", "Memory headroom"}]
    hardware_summary = "The scanned hardware is suitable for a Ceph production design." if not hw_blockers else "The scanned hardware is not yet sufficient for the proposed Ceph production design."
    production_summary = "Ceph can only be called production-ready after all blockers are removed and the critical topology/operations unknowns are verified."
    return Assessment("Ceph", checks, hardware_summary, production_summary)


def assess_openstack(env: Environment, cur: dict[str, str], detected: dict[str, str], ceph: Assessment, components: dict[str, list[str]]) -> Assessment:
    checks: list[Check] = []
    nodes = env.nodes
    n = len(nodes)
    checks.append(Check("PASS" if n >= 3 else "BLOCKER", "Minimum cluster size", f"{n} scanned host(s). A resilient OpenStack control plane normally needs at least three failure-domain-separated hosts.", "Provide at least three hosts." if n < 3 else "", 10, True))

    checks.append(talos_lifecycle_check(env, cur["talos"]))

    cp = [v for v in env.cluster.nodes.values() if v.get("role") == "control-plane"]
    if env.cluster.k8s_connected:
        checks.append(Check("PASS" if len(cp) >= 3 else "BLOCKER", "Control-plane HA", f"Kubernetes reports {len(cp)} control-plane node(s).", "Use at least three control-plane nodes." if len(cp) < 3 else "", 10, True))
    else:
        checks.append(Check("UNKNOWN", "Control-plane HA", "No authenticated Kubernetes node-role summary is available.", "Capture cluster node roles.", 10, True))

    kvm_yes = [x for x in nodes if x.hw_virt == "yes" and (x.kvm_device == "yes" or x.kvm_module == "yes")]
    virt_unknown = [x for x in nodes if x.hw_virt == "unknown" or (x.kvm_device == "unknown" and x.kvm_module == "unknown")]
    if kvm_yes:
        checks.append(Check("PASS", "KVM compute capability", f"KVM/hardware virtualization evidence is present on {len(kvm_yes)} scanned node(s).", weight=16))
    elif virt_unknown:
        checks.append(Check("UNKNOWN", "KVM compute capability", f"KVM capability is unproven on {len(virt_unknown)} node(s).", "Run the current collector so /dev/kvm, CPU VMX/SVM and KVM modules are captured.", 16, True))
    else:
        checks.append(Check("BLOCKER", "KVM compute capability", "No scanned node has both hardware virtualization and KVM evidence.", "Enable VT-x/AMD-V and expose /dev/kvm/KVM modules to the compute workload.", 16, True))

    compute_basis = kvm_yes or nodes
    if compute_basis:
        low = [x for x in compute_basis if x.mem_gib < 32]
        checks.append(Check("PASS" if not low else "WARN", "Compute memory", f"Minimum RAM across compute candidates is {min(x.mem_gib for x in compute_basis):.1f} GiB.", "For general-purpose production compute, increase RAM on low-memory nodes or constrain scheduling." if low else "", 8))
        lowcpu = [x for x in compute_basis if x.logical_cpus < 8]
        checks.append(Check("PASS" if not lowcpu else "WARN", "Compute CPU", f"Minimum logical CPU count across compute candidates is {min(x.logical_cpus for x in compute_basis)}.", "Increase CPU capacity or constrain workload density." if lowcpu else "", 6))

    links = [x.max_physical_link_mbps for x in nodes if x.max_physical_link_mbps]
    if not links:
        checks.append(Check("UNKNOWN", "OpenStack data-plane bandwidth", "No active physical NIC speeds could be established.", "Capture host NIC speed/topology.", 10, True))
    elif min(links) < 10000:
        checks.append(Check("WARN", "OpenStack data-plane bandwidth", f"Slowest node's active physical link is {min(links)/1000:.1f} Gb/s. OpenStack can function on slower links, but this is a serious general-purpose production bottleneck.", "Use >=10 Gb/s for management/storage/tenant traffic, with separation or QoS as appropriate.", 10))
    else:
        checks.append(Check("PASS", "OpenStack data-plane bandwidth", f"All scanned nodes expose an active physical link of at least 10 Gb/s; minimum is {min(links)/1000:.1f} Gb/s.", weight=10))

    iommu_yes = [x for x in nodes if x.iommu == "yes"]
    sriov = sum(1 for x in nodes if any(i.sriov_total > 0 for i in x.nets))
    if iommu_yes or sriov:
        checks.append(Check("PASS", "Advanced I/O capability", f"IOMMU is observed on {len(iommu_yes)} node(s); SR-IOV-capable NICs on {sriov} node(s). This is useful for PCI/SR-IOV passthrough but not mandatory for basic OpenStack.", weight=5))
    else:
        checks.append(Check("WARN", "Advanced I/O capability", "IOMMU/SR-IOV was not observed. Basic OpenStack does not require it, but NFV/direct-device workloads will.", "Enable and validate IOMMU/SR-IOV if those workload classes are in scope.", 5))

    if ceph.verdict == "PRODUCTION-CAPABLE":
        checks.append(Check("PASS", "Production storage backend", "The accompanying Ceph assessment is production-capable.", weight=8))
    elif components["ceph"] or env.cluster.cephclusters:
        checks.append(Check("WARN" if not ceph.blockers else "BLOCKER", "Production storage backend", f"Ceph is detected, but its readiness verdict is: {ceph.verdict}.", "Resolve Ceph blockers/unknowns before using it as the OpenStack production storage backend.", 8, True))
    else:
        checks.append(Check("UNKNOWN", "Production storage backend", "No validated OpenStack storage backend is established by the scan.", "Validate Ceph or another production storage backend for Glance/Cinder/Nova ephemeral needs.", 8, True))

    os_components = components["openstack"]
    if os_components:
        failed = [(ns, name, p.get("phase")) for (ns, name), p in env.cluster.pods.items() if any(s.lower() in (ns + " " + name).lower() for s in [x.lower() for x in os_components]) and p.get("phase") not in {"Running", "Succeeded"}]
        checks.append(Check("PASS" if not failed else "BLOCKER", "Existing OpenStack workloads", f"Detected components: {', '.join(os_components)}." + (" No failed/non-running matching pods were seen." if not failed else f" {len(failed)} matching pod(s) are not Running/Succeeded."), "Resolve unhealthy OpenStack pods." if failed else "", 8, True))
    else:
        checks.append(Check("UNKNOWN", "Existing OpenStack deployment", "No OpenStack services were detected in the Kubernetes summary. This is therefore primarily a hardware/platform suitability assessment.", weight=4))

    # This is intentionally not auto-passed by hardware inventory.
    if os_components and kvm_yes:
        checks.append(Check("WARN", "Talos/OpenStack compute integration", "OpenStack services and KVM-capable nodes are visible, but a scan cannot prove that Nova/libvirt device access, privileged workloads, networking and upgrade procedures are fully validated on Talos.", "Run a controlled Nova compute validation: VM create/delete, live migration, evacuation, reboot, network attach/detach and host upgrade/reboot.", 12, True))
    else:
        checks.append(Check("UNKNOWN", "Talos/OpenStack compute integration", "Hardware suitability does not establish that Nova/libvirt/KVM integration on Talos is production-supported and operationally validated.", "Prototype and validate Nova compute/libvirt/KVM, CNI/Neutron integration, host upgrades and failure recovery on this exact Talos design.", 12, True))

    checks.append(Check("UNKNOWN", "API/database/message-bus HA", "A hardware scan cannot prove HAProxy/Ingress/VIP, MariaDB/Galera, RabbitMQ quorum, fencing or API failover behavior.", "Validate service quorum and failover under host loss.", 7, True))
    checks.append(Check("UNKNOWN", "Operational recovery", "The scan cannot prove backup/restore, control-plane recovery, compute evacuation, image recovery or upgrade rollback.", "Perform failure and recovery tests before production sign-off.", 7, True))

    hardware_blockers = [c for c in checks if c.status == "BLOCKER" and c.title in {"Minimum cluster size", "KVM compute capability", "Compute memory", "Compute CPU", "OpenStack data-plane bandwidth"}]
    hardware_summary = "The scanned hardware is capable of hosting a serious OpenStack compute/control-plane design." if not hardware_blockers and kvm_yes else ("The hardware looks promising, but KVM capability is not yet proven." if not hardware_blockers else "The scanned hardware currently has blocking gaps for the proposed OpenStack production design.")
    production_summary = "Even when the hardware passes, OpenStack on Talos should not be labelled production-ready until the Talos/Nova/libvirt/network integration and HA/recovery tests are explicitly validated."
    return Assessment("OpenStack", checks, hardware_summary, production_summary)


# ----------------------------- Report rendering -----------------------------

def status_class(s: str) -> str:
    return {"PASS": "pass", "WARN": "warn", "UNKNOWN": "unknown", "BLOCKER": "blocker"}.get(s, "unknown")


def node_role(env: Environment, node: Node) -> str:
    if node.name in env.cluster.nodes:
        return env.cluster.nodes[node.name].get("role", "")
    if node.etcd_data == "present":
        return "control-plane?"
    if node.kubelet_state:
        return "kubernetes node"
    return "host"


def currentness_rows(env: Environment, detected: dict[str, str], cur: dict[str, str], prov: dict[str, str]) -> list[list[str]]:
    rows = []
    talos_obs = ", ".join(sorted({n.talos_version for n in env.nodes if n.talos_version}, key=ver_tuple)) or "unknown"
    rows.append(["Talos", talos_obs, cur["talos"], prov["talos"]])
    rows.append(["Ceph", detected.get("ceph", "not detected"), cur["ceph"], prov["ceph"]])
    rows.append(["Rook", detected.get("rook", "not detected"), cur["rook"], prov["rook"]])
    rows.append(["OpenStack", detected.get("openstack", "not detected"), cur["openstack"], prov["openstack"]])
    if env.cluster.k8s_server_version:
        rows.append(["Kubernetes", env.cluster.k8s_server_version, "not live-compared", "captured cluster value"])
    return rows


def assessment_explanation(a: Assessment) -> str:
    blockers = [c.title for c in a.blockers]
    unknowns = [c.title for c in a.critical_unknowns]
    if blockers:
        return f"{a.name} is not production-ready because the scan found blocking issues in: {', '.join(blockers)}. {a.hardware_summary}"
    if unknowns:
        return f"{a.name} has no observed hard blocker, but production readiness cannot be asserted yet because critical evidence is still missing for: {', '.join(unknowns)}. {a.hardware_summary}"
    return f"{a.name} has no blocking or critical-unknown checks in the captured evidence. {a.hardware_summary}"


def render_html(env: Environment, components: dict[str, list[str]], detected: dict[str, str], cur: dict[str, str], prov: dict[str, str], ceph: Assessment, openstack: Assessment) -> str:
    generated = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    def check_rows(a: Assessment) -> str:
        rows = []
        for c in a.checks:
            rows.append(f"<tr><td><span class='pill {status_class(c.status)}'>{safe(c.status)}</span></td><td><strong>{safe(c.title)}</strong><div class='small'>{safe(c.detail)}</div></td><td>{safe(c.recommendation) or '—'}</td></tr>")
        return "".join(rows)

    node_cards = []
    for n in env.nodes:
        phys = [x for x in n.nets if x.physical]
        links = ", ".join(f"{x.name} {x.speed_mbps/1000:g}G {x.state}" if x.speed_mbps else f"{x.name} {x.state}" for x in phys[:6]) or "not observed"
        disks = ", ".join(f"{d.name} {d.gib:.0f}GiB {d.model}" for d in n.disks[:6]) or "not observed"
        node_cards.append(f"""
        <div class='node-card'>
          <div class='node-title'>{safe(n.name)}</div>
          <div class='muted'>{safe(node_role(env,n))} · {safe(n.manufacturer)} {safe(n.model)}</div>
          <div class='kv'><span>Talos</span><b>{safe(n.talos_version or 'unknown')}</b><span>Kernel</span><b>{safe(n.kernel or 'unknown')}</b><span>CPU</span><b>{n.logical_cpus} logical</b><span>RAM</span><b>{n.mem_gib:.1f} GiB</b><span>Disks</span><b>{len(n.disks)} / {n.osd_candidate_count} OSD candidates</b><span>KVM</span><b>{safe(n.kvm_device)} / {safe(n.kvm_module)}</b></div>
          <div class='small'><b>NICs:</b> {safe(links)}</div>
          <div class='small'><b>Storage:</b> {safe(disks)}</div>
        </div>""")

    comp_badges = []
    for group, vals in components.items():
        if vals:
            comp_badges.append(f"<div><b>{safe(group.title())}:</b> " + " ".join(f"<span class='tag'>{safe(v)}</span>" for v in vals) + "</div>")
    if not comp_badges:
        comp_badges = ["<div class='muted'>No Ceph/OpenStack/CNI components could be confidently identified from cluster-level evidence.</div>"]

    node_table = "".join(
        f"<tr><td>{safe(n.name)}</td><td>{safe(node_role(env,n))}</td><td>{safe(n.talos_version or 'unknown')}</td><td>{n.logical_cpus}</td><td>{n.mem_gib:.1f}</td><td>{len(n.disks)}</td><td>{n.osd_candidate_count}</td><td>{n.max_physical_link_mbps/1000:g}G</td></tr>"
        for n in env.nodes
    )
    storage_rows = "".join(
        f"<tr><td>{safe(n.name)}</td><td>{safe(d.name)}</td><td>{d.gib:.1f} GiB</td><td>{'SSD/NVMe' if d.rotational == '0' else 'rotational' if d.rotational == '1' else safe(d.rotational)}</td><td>{safe(d.model)}</td></tr>"
        for n in env.nodes for d in n.disks
    ) or "<tr><td colspan='5'>No disks observed.</td></tr>"
    network_rows = "".join(
        f"<tr><td>{safe(n.name)}</td><td>{safe(x.name)}</td><td>{safe(x.state)}</td><td>{x.speed_mbps/1000:g}G</td><td>{x.mtu}</td><td>{safe(x.driver)}</td><td>{x.sriov_total}</td></tr>"
        for n in env.nodes for x in n.physical_nics
    ) or "<tr><td colspan='7'>No physical NICs observed.</td></tr>"
    curr_rows = "".join(f"<tr><td>{safe(r[0])}</td><td>{safe(r[1])}</td><td>{safe(r[2])}</td><td>{safe(r[3])}</td></tr>" for r in currentness_rows(env, detected, cur, prov))

    warnings = "".join(f"<li>{safe(w)}</li>" for w in env.parse_warnings)
    ceph_exp = assessment_explanation(ceph)
    os_exp = assessment_explanation(openstack)

    return f"""<!doctype html>
<html><head><meta charset='utf-8'><title>PACDIAG Environment Report</title>
<style>
@page {{ size: A4; margin: 14mm; }}
:root{{--ink:#17212b;--muted:#5d6975;--line:#d7dde3;--bg:#f4f6f8;--card:#fff;--pass:#176b41;--passbg:#e8f6ef;--warn:#8a5a00;--warnbg:#fff4d6;--unknown:#56606a;--unknownbg:#eef1f4;--block:#9b1c1c;--blockbg:#fdecec;--accent:#245a7a;}}
*{{box-sizing:border-box}} body{{font-family:Inter,Segoe UI,Arial,sans-serif;color:var(--ink);margin:0;background:#fff;line-height:1.38;font-size:14px}} main{{max-width:1120px;margin:0 auto;padding:28px}} h1{{font-size:30px;margin:0 0 5px}} h2{{font-size:21px;border-bottom:1px solid var(--line);padding-bottom:6px;margin-top:30px}} h3{{font-size:16px;margin:18px 0 8px}} .muted,.small{{color:var(--muted)}} .small{{font-size:12px;margin-top:7px}} .hero{{padding:18px 20px;background:var(--bg);border-left:5px solid var(--accent);margin:18px 0}} .summary-grid,.nodes{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px}} .summary,.node-card{{border:1px solid var(--line);border-radius:9px;padding:15px;background:var(--card)}} .summary .score{{font-size:32px;font-weight:700}} .verdict{{font-weight:700;margin:3px 0 8px}} .node-title{{font-size:17px;font-weight:700}} .kv{{display:grid;grid-template-columns:auto 1fr;gap:3px 12px;margin:10px 0;font-size:12px}} .kv span{{color:var(--muted)}} table{{width:100%;border-collapse:collapse;margin:10px 0 18px;font-size:12px}} th,td{{border:1px solid var(--line);padding:7px 8px;vertical-align:top;text-align:left}} th{{background:var(--bg)}} .pill,.tag{{display:inline-block;border-radius:999px;padding:2px 7px;font-size:11px;font-weight:700;white-space:nowrap}} .tag{{background:#e8eef2;color:#2a4b60;margin:2px}} .pass{{background:var(--passbg);color:var(--pass)}} .warn{{background:var(--warnbg);color:var(--warn)}} .unknown{{background:var(--unknownbg);color:var(--unknown)}} .blocker{{background:var(--blockbg);color:var(--block)}} .callout{{padding:12px;border:1px solid var(--line);border-radius:7px;margin:10px 0}} code{{background:var(--bg);padding:1px 4px;border-radius:3px}} ul{{padding-left:22px}} footer{{margin-top:36px;border-top:1px solid var(--line);padding-top:12px;color:var(--muted);font-size:11px}} @media print{{main{{padding:0}} .node-card,.summary{{break-inside:avoid}} h2{{break-after:avoid}}}}
</style></head><body><main>
<h1>Talos / Kubernetes Environment Diagnostic</h1>
<div class='muted'>Generated {safe(generated)} · PACDIAG reporter {TOOL_VERSION} · {len(env.nodes)} scanned host(s)</div>
<div class='hero'><b>Purpose:</b> inventory the captured environment and answer whether the observed hardware and platform evidence is sufficient for a production Ceph or OpenStack design. A host scan cannot prove physical failure-domain separation, operational procedures or vendor support; those remain explicit UNKNOWN checks instead of being silently assumed.</div>

<h2>Executive verdict</h2>
<div class='summary-grid'>
  <div class='summary'><div class='muted'>Ceph readiness</div><div class='score'>{ceph.score}/100</div><div class='verdict'>{safe(ceph.verdict)}</div><div>{safe(ceph_exp)}</div></div>
  <div class='summary'><div class='muted'>OpenStack readiness</div><div class='score'>{openstack.score}/100</div><div class='verdict'>{safe(openstack.verdict)}</div><div>{safe(os_exp)}</div></div>
</div>

<h2>Environment overview</h2>
<div class='callout'>{''.join(comp_badges)}</div>
<div class='nodes'>{''.join(node_cards)}</div>

<h3>Node inventory</h3>
<table><thead><tr><th>Node</th><th>Role/evidence</th><th>Talos</th><th>Logical CPU</th><th>RAM GiB</th><th>Disks</th><th>OSD candidates*</th><th>Fastest active physical link</th></tr></thead><tbody>{node_table}</tbody></table>
<div class='small'>* Conservative OSD heuristic reserves one physical disk per host for Talos/system use. It does not claim that remaining disks are actually raw/empty until that is verified.</div>

<h2>Detected cluster components</h2>
<div class='callout'><b>Kubernetes API captured:</b> {'yes' if env.cluster.k8s_connected else 'no'} · <b>Server version:</b> {safe(env.cluster.k8s_server_version or 'unknown')} · <b>Cluster nodes in API summary:</b> {len(env.cluster.nodes)} · <b>Pods:</b> {len(env.cluster.pods)} · <b>StorageClasses:</b> {len(env.cluster.storageclasses)}</div>
<p>{''.join(comp_badges)}</p>

<h2>Storage inventory</h2>
<table><thead><tr><th>Node</th><th>Device</th><th>Size</th><th>Media</th><th>Model</th></tr></thead><tbody>{storage_rows}</tbody></table>

<h2>Physical network inventory</h2>
<table><thead><tr><th>Node</th><th>Interface</th><th>State</th><th>Speed</th><th>MTU</th><th>Driver</th><th>SR-IOV max VFs</th></tr></thead><tbody>{network_rows}</tbody></table>

<h2>How current is it?</h2>
<table><thead><tr><th>Component</th><th>Observed</th><th>Current reference</th><th>Reference mode</th></tr></thead><tbody>{curr_rows}</tbody></table>

<h2>Ceph production assessment</h2>
<p>{safe(ceph.hardware_summary)} {safe(ceph.production_summary)}</p>
<table><thead><tr><th>Status</th><th>Check / evidence</th><th>Action</th></tr></thead><tbody>{check_rows(ceph)}</tbody></table>

<h2>OpenStack production assessment</h2>
<p>{safe(openstack.hardware_summary)} {safe(openstack.production_summary)}</p>
<table><thead><tr><th>Status</th><th>Check / evidence</th><th>Action</th></tr></thead><tbody>{check_rows(openstack)}</tbody></table>

<h2>Interpretation</h2>
<div class='callout'><b>PASS</b> means the captured evidence satisfies the tool's baseline. <b>WARN</b> is a real production risk or design preference, but not an automatic hard stop. <b>UNKNOWN</b> means the scan cannot prove the condition. <b>BLOCKER</b> means the observed evidence is incompatible with the baseline production design.</div>
{('<h3>Parser warnings</h3><ul>'+warnings+'</ul>') if warnings else ''}

<h2>Reference baseline</h2>
<ul>
<li>Ceph: at least 10 Gb/s between hosts/clients; 25 Gb/s preferred for substantial workloads; active/active bonding across separate switches strongly recommended; separate OS and OSD drives recommended.</li>
<li>Talos: current reference {safe(cur['talos'])}; lifecycle check treats being two or more minor release lines behind as outside the normal latest-two-minors security window.</li>
<li>OpenStack: current released series reference {safe(cur['openstack'])}. Hardware readiness is intentionally separate from Talos/Nova/libvirt integration validation.</li>
</ul>
<footer>Sources: {safe(SOURCES['ceph_hw'])} · {safe(SOURCES['ceph_net'])} · {safe(SOURCES['ceph'])} · {safe(SOURCES['talos'])} · {safe(SOURCES['rook'])} · {safe(SOURCES['openstack'])}</footer>
</main></body></html>"""


def render_markdown(env: Environment, components: dict[str, list[str]], detected: dict[str, str], cur: dict[str, str], prov: dict[str, str], ceph: Assessment, openstack: Assessment) -> str:
    lines = [
        "# Talos / Kubernetes Environment Diagnostic", "",
        f"Generated: {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}", "",
        "## Executive verdict", "",
        f"- **Ceph:** {ceph.verdict} ({ceph.score}/100) - {assessment_explanation(ceph)}",
        f"- **OpenStack:** {openstack.verdict} ({openstack.score}/100) - {assessment_explanation(openstack)}", "",
        "## Environment", "",
    ]
    for n in env.nodes:
        lines.append(f"- **{n.name}** - {node_role(env,n)}; Talos {n.talos_version or 'unknown'}; {n.logical_cpus} logical CPUs; {n.mem_gib:.1f} GiB RAM; {len(n.disks)} disk(s); {n.osd_candidate_count} conservative OSD candidate(s); max active physical link {n.max_physical_link_mbps/1000:g} Gb/s")
    lines += ["", "## Detected components", "", f"- CNI: {', '.join(components['cni']) or 'not identified'}", f"- Ceph/Rook: {', '.join(components['ceph']) or 'not detected'}", f"- OpenStack: {', '.join(components['openstack']) or 'not detected'}", ""]
    for a in (ceph, openstack):
        lines += [f"## {a.name} readiness", "", f"**{a.verdict} - {a.score}/100**", "", a.hardware_summary, "", a.production_summary, "", "| Status | Check | Evidence | Action |", "|---|---|---|---|"]
        for c in a.checks:
            lines.append(f"| {c.status} | {c.title} | {c.detail.replace('|','/')} | {(c.recommendation or '—').replace('|','/')} |")
        lines.append("")
    lines += ["## Currentness", "", "| Component | Observed | Current | Source mode |", "|---|---|---|---|"]
    for r in currentness_rows(env, detected, cur, prov):
        lines.append("| " + " | ".join(r) + " |")
    return "\n".join(lines) + "\n"


def render_pdf(path: Path, env: Environment, components: dict[str, list[str]], detected: dict[str, str], cur: dict[str, str], prov: dict[str, str], ceph: Assessment, openstack: Assessment) -> bool:
    try:
        from reportlab.lib import colors
        from reportlab.lib.enums import TA_LEFT
        from reportlab.lib.pagesizes import A4
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import mm
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, KeepTogether
    except Exception:
        return False

    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="Small", parent=styles["BodyText"], fontSize=8.5, leading=11))
    styles.add(ParagraphStyle(name="Tiny", parent=styles["BodyText"], fontSize=7.3, leading=9))
    styles.add(ParagraphStyle(name="Verdict", parent=styles["Heading2"], fontSize=13, leading=16, spaceAfter=6))
    doc = SimpleDocTemplate(str(path), pagesize=A4, rightMargin=12*mm, leftMargin=12*mm, topMargin=13*mm, bottomMargin=13*mm, title="PACDIAG Environment Report")
    story = []
    story += [Paragraph("Talos / Kubernetes Environment Diagnostic", styles["Title"]), Paragraph(f"Generated {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} - PACDIAG reporter {TOOL_VERSION}", styles["Small"]), Spacer(1, 5*mm)]

    def verdict_block(a: Assessment):
        data = [[Paragraph(a.name, styles["Heading3"]), Paragraph(f"<b>{a.score}/100</b><br/>{a.verdict}", styles["BodyText"])], [Paragraph(assessment_explanation(a), styles["Small"]), ""]]
        t = Table(data, colWidths=[65*mm, 105*mm])
        t.setStyle(TableStyle([("BOX",(0,0),(-1,-1),0.5,colors.HexColor("#cfd6dd")),("INNERGRID",(0,0),(-1,-1),0.25,colors.HexColor("#e0e5ea")),("BACKGROUND",(0,0),(-1,0),colors.HexColor("#f3f5f7")),("VALIGN",(0,0),(-1,-1),"TOP"),("PADDING",(0,0),(-1,-1),6),("SPAN",(0,1),(1,1))]))
        return t
    story += [verdict_block(ceph), Spacer(1, 3*mm), verdict_block(openstack), Spacer(1, 5*mm)]

    story += [Paragraph("Environment overview", styles["Heading2"])]
    node_data = [["Node", "Role", "Talos", "CPU", "RAM", "Disks", "OSD cand.", "Link"]]
    for n in env.nodes:
        node_data.append([n.name, node_role(env,n), n.talos_version or "?", str(n.logical_cpus), f"{n.mem_gib:.1f}G", str(len(n.disks)), str(n.osd_candidate_count), f"{n.max_physical_link_mbps/1000:g}G"])
    nt = Table(node_data, repeatRows=1, colWidths=[31*mm,23*mm,16*mm,12*mm,15*mm,12*mm,15*mm,14*mm])
    nt.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,0),colors.HexColor("#e9eef2")),("GRID",(0,0),(-1,-1),0.35,colors.HexColor("#cfd6dd")),("FONTSIZE",(0,0),(-1,-1),7.5),("VALIGN",(0,0),(-1,-1),"TOP"),("PADDING",(0,0),(-1,-1),4)]))
    story += [nt, Spacer(1, 4*mm)]
    story += [Paragraph(f"Detected CNI: {', '.join(components['cni']) or 'not identified'}; Ceph/Rook: {', '.join(components['ceph']) or 'not detected'}; OpenStack: {', '.join(components['openstack']) or 'not detected'}.", styles["Small"]), Spacer(1, 4*mm)]

    story += [Paragraph("Currentness", styles["Heading2"])]
    cr = [["Component","Observed","Current reference","Mode"]] + currentness_rows(env, detected, cur, prov)
    ct = Table(cr, repeatRows=1, colWidths=[28*mm,42*mm,42*mm,58*mm])
    ct.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,0),colors.HexColor("#e9eef2")),("GRID",(0,0),(-1,-1),0.35,colors.HexColor("#cfd6dd")),("FONTSIZE",(0,0),(-1,-1),7.5),("VALIGN",(0,0),(-1,-1),"TOP"),("PADDING",(0,0),(-1,-1),4)]))
    story += [ct, PageBreak()]

    status_bg = {"PASS":"#e8f6ef","WARN":"#fff4d6","UNKNOWN":"#eef1f4","BLOCKER":"#fdecec"}
    for a in (ceph, openstack):
        story += [Paragraph(f"{a.name} production assessment", styles["Heading2"]), Paragraph(a.hardware_summary + " " + a.production_summary, styles["BodyText"]), Spacer(1, 3*mm)]
        data = [["Status","Check / evidence","Action"]]
        for c in a.checks:
            data.append([c.status, Paragraph(f"<b>{c.title}</b><br/>{safe(c.detail)}", styles["Tiny"]), Paragraph(safe(c.recommendation or "—"), styles["Tiny"])])
        t = Table(data, repeatRows=1, colWidths=[21*mm,95*mm,54*mm])
        ts = [("BACKGROUND",(0,0),(-1,0),colors.HexColor("#e9eef2")),("GRID",(0,0),(-1,-1),0.35,colors.HexColor("#cfd6dd")),("FONTSIZE",(0,0),(-1,-1),7.2),("VALIGN",(0,0),(-1,-1),"TOP"),("PADDING",(0,0),(-1,-1),4)]
        for i,c in enumerate(a.checks, start=1):
            ts.append(("BACKGROUND",(0,i),(0,i),colors.HexColor(status_bg[c.status])))
        t.setStyle(TableStyle(ts))
        story += [t, Spacer(1, 5*mm)]

    story += [Paragraph("Evidence caveats", styles["Heading2"]), Paragraph("A machine scan cannot prove rack/PDU/switch independence, enterprise-drive power-loss protection, backups, recovery testing, operational support or change procedures. UNKNOWN is therefore a deliberate result, not a failure of the scanner.", styles["BodyText"]), Spacer(1, 3*mm), Paragraph("Official reference URLs", styles["Heading3"])]
    for k in ["talos","rook","ceph","ceph_hw","ceph_net","openstack"]:
        story.append(Paragraph(SOURCES[k], styles["Tiny"]))

    def add_page_number(canvas, docobj):
        canvas.saveState(); canvas.setFont("Helvetica", 7); canvas.setFillColor(colors.grey)
        canvas.drawRightString(A4[0]-12*mm, 7*mm, f"PACDIAG - page {docobj.page}")
        canvas.restoreState()
    doc.build(story, onFirstPage=add_page_number, onLaterPages=add_page_number)
    return True


def as_jsonable(env: Environment, components: dict[str, list[str]], detected: dict[str, str], cur: dict[str, str], prov: dict[str, str], ceph: Assessment, openstack: Assessment) -> dict[str, Any]:
    return {
        "reporter_version": TOOL_VERSION,
        "generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "nodes": [dataclasses.asdict(x) for x in env.nodes],
        "cluster": {
            "k8s_connected": env.cluster.k8s_connected,
            "k8s_server_version": env.cluster.k8s_server_version,
            "nodes": env.cluster.nodes,
            "pods": [{"namespace": k[0], "name": k[1], **v} for k,v in env.cluster.pods.items()],
            "workloads": [{"kind": k[0], "namespace": k[1], "name": k[2], **v} for k,v in env.cluster.workloads.items()],
            "storageclasses": env.cluster.storageclasses,
            "cephclusters": [{"namespace":k[0],"name":k[1],**v} for k,v in env.cluster.cephclusters.items()],
        },
        "components": components,
        "detected_versions": detected,
        "current_versions": cur,
        "current_version_provenance": prov,
        "ceph": {"score": ceph.score, "verdict": ceph.verdict, "hardware_summary": ceph.hardware_summary, "production_summary": ceph.production_summary, "checks": [dataclasses.asdict(c) for c in ceph.checks]},
        "openstack": {"score": openstack.score, "verdict": openstack.verdict, "hardware_summary": openstack.hardware_summary, "production_summary": openstack.production_summary, "checks": [dataclasses.asdict(c) for c in openstack.checks]},
        "parse_warnings": env.parse_warnings,
        "sources": SOURCES,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Turn PACDIAG bundles or legacy scan.sh output into a Ceph/OpenStack production-readiness report.")
    ap.add_argument("inputs", nargs="*", help="Bundle/text files or directories. Use - for stdin.")
    ap.add_argument("-o", "--output-dir", default="pacdiag-report", help="Output directory (default: pacdiag-report)")
    ap.add_argument("--paste", action="store_true", help="Read pasted input from stdin until EOF (Ctrl-D on Unix/macOS; Ctrl-Z then Enter on Windows console).")
    ap.add_argument("--offline", action="store_true", help="Do not attempt live version lookups; use the embedded baseline.")
    ap.add_argument("--no-pdf", action="store_true", help="Skip PDF generation even if reportlab is installed.")
    args = ap.parse_args()

    env = Environment()
    if args.paste or args.inputs == ["-"] or (not args.inputs and not sys.stdin.isatty()):
        if args.paste and sys.stdin.isatty():
            print("Paste one or more PACDIAG blocks / legacy scans, then send EOF:", file=sys.stderr)
            print("  Linux/macOS: Ctrl-D", file=sys.stderr)
            print("  Windows console: Ctrl-Z then Enter", file=sys.stderr)
        text = sys.stdin.read()
        extract_inputs(text, "stdin", env)
    else:
        paths = collect_paths(args.inputs)
        if not paths:
            ap.error("No readable input files found. Use --paste, '-', or provide files/directories.")
        for p in paths:
            try:
                extract_inputs(p.read_text(encoding="utf-8", errors="replace"), str(p), env)
            except Exception as e:
                env.parse_warnings.append(f"{p}: {e}")

    # Deduplicate nodes by hostname; merge incomplete duplicates.
    merged: dict[str, Node] = {}
    for n in env.nodes:
        key = n.name or n.source
        if key in merged:
            merge_node(merged[key], n)
        else:
            merged[key] = n
    env.nodes = sorted(merged.values(), key=lambda x: x.name)
    if not env.nodes:
        print("No node scans could be parsed.", file=sys.stderr)
        return 2

    cur, prov = current_versions(args.offline)
    components = detect_components(env)
    detected = detect_versions(env)
    ceph = assess_ceph(env, cur, detected)
    openstack = assess_openstack(env, cur, detected, ceph, components)

    outdir = Path(args.output_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    html_path = outdir / "environment-report.html"
    md_path = outdir / "environment-report.md"
    json_path = outdir / "environment-data.json"
    pdf_path = outdir / "environment-report.pdf"
    html_path.write_text(render_html(env, components, detected, cur, prov, ceph, openstack), encoding="utf-8")
    md_path.write_text(render_markdown(env, components, detected, cur, prov, ceph, openstack), encoding="utf-8")
    json_path.write_text(json.dumps(as_jsonable(env, components, detected, cur, prov, ceph, openstack), indent=2), encoding="utf-8")
    pdf_ok = False if args.no_pdf else render_pdf(pdf_path, env, components, detected, cur, prov, ceph, openstack)

    print(f"Parsed nodes: {len(env.nodes)}")
    print(f"Ceph:      {ceph.verdict} ({ceph.score}/100)")
    print(f"OpenStack: {openstack.verdict} ({openstack.score}/100)")
    print(f"HTML: {html_path}")
    print(f"Markdown: {md_path}")
    print(f"JSON: {json_path}")
    if pdf_ok:
        print(f"PDF: {pdf_path}")
    elif not args.no_pdf:
        print("PDF: not generated (install reportlab: python -m pip install reportlab)")
    return 1 if ceph.blockers or openstack.blockers else 0


if __name__ == "__main__":
    raise SystemExit(main())
