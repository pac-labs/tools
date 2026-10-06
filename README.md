# PACDIAG Talos / Ceph / OpenStack diagnostic toolkit

PACDIAG is a two-stage diagnostic workflow:

1. `collect.sh` runs from a diagnostic container with the host filesystem mounted at `/host-root`.
2. `report.py` accepts any number of copied PACDIAG bundles or older human-readable `scan.sh` outputs and generates an environment/readiness report.

The report separates **hardware capability** from **production validation**. Unknown physical topology or operational requirements remain `UNKNOWN`; they are never silently assumed to be healthy.

## 1. Collect on each Talos node

Once `collect.sh` is published in `pac-labs/tools`:

```sh
curl -fsSL https://raw.githubusercontent.com/pac-labs/tools/refs/heads/main/collect.sh | sh
```

The command prints one copy/paste-safe block:

```text
-----BEGIN PACDIAG V1-----
...
-----END PACDIAG V1-----
```

Run it on as many nodes as needed and copy every complete block.

To redact MAC/IP data where supported:

```sh
curl -fsSL https://raw.githubusercontent.com/pac-labs/tools/refs/heads/main/collect.sh | PACDIAG_REDACT_NETWORK=1 sh
```

PACDIAG is compressed and base64-encoded for terminal transport. **It is not encryption.**

## 2A. Generate a report locally

Install Python 3, then:

```sh
python -m pip install -r requirements.txt
python report.py --paste
```

Paste all bundles, then send EOF:

- Linux/macOS: `Ctrl-D`
- Windows console: `Ctrl-Z`, then `Enter`

Outputs are written to `pacdiag-report/`:

- `environment-report.html`
- `environment-report.pdf`
- `environment-report.md`
- `environment-data.json`

On Windows, `run-report.ps1` installs the small dependency and opens the generated HTML report.

## 2B. Generate from files/directories

```sh
python report.py diagnostics/input -o diagnostics/generated
```

The reporter also understands previous `HOST MACHINE REPORT` output from `scan.sh`.

## 2C. GitHub workflow

Copy `.github/workflows/build-diagnostic-report.yml`, `report.py`, `requirements.txt`, and the `diagnostics/` directory into the repository.

Paste bundles into a text file under `diagnostics/input/`, commit and push. The workflow:

- generates HTML/PDF/Markdown/JSON;
- uploads them as a workflow artifact;
- commits the generated reports under `diagnostics/generated/` on push.

Use a private repository unless the captured infrastructure information is safe to publish.

## What is evaluated

### Ceph

- number of independent hosts observed;
- conservative dedicated OSD disk candidates;
- CPU/RAM headroom;
- >=10 Gb/s storage/client networking and 25 Gb/s preference;
- LACP evidence;
- Talos lifecycle/currentness;
- Kubernetes control-plane HA when cluster API data is available;
- Rook/Ceph versions and Ceph health when detected;
- explicit unknowns for rack/power/switch failure domains, PLP/endurance, and recovery testing.

### OpenStack

- HA-sized host/control-plane footprint;
- KVM/VT-x/AMD-V evidence;
- compute CPU/RAM;
- data-plane bandwidth;
- IOMMU/SR-IOV capability;
- storage-backend readiness;
- detected OpenStack components/pod health;
- Talos lifecycle;
- explicit Talos/Nova/libvirt integration validation;
- API/database/message-bus HA and recovery testing.

The tool intentionally does **not** claim that OpenStack is production-supported on Talos merely because the hardware supports KVM.

## Current reference baseline

The reporter tries live lookups for Talos, Rook and Ceph and records whether a value was live-fetched or came from the embedded baseline. The embedded 2026-10-06 baseline is:

- Talos 1.14.1
- Rook 1.20.8
- Ceph 20.2.4 Tentacle
- OpenStack 2026.2 Hibiscus

Official reference URLs are embedded in the generated report.
