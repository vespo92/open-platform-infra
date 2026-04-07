# Open Platform Infrastructure

Bare-metal infrastructure layer for [Open Platform](https://github.com/Trevato/open-platform). Sets up NixOS + K3s + infrastructure services so Open Platform can deploy into its own vCluster with `infrastructure.mode=external`.

## What this provides

| Layer | Components | Purpose |
|-------|-----------|---------|
| **Hardware** | NixOS, ZFS, 10G bonding, GPU passthrough | Bare-metal foundation |
| **Kubernetes** | K3s (HA etcd, multi-node) | Container orchestration |
| **Networking** | Traefik, MetalLB, VLAN segmentation | Ingress, load balancing, isolation |
| **Storage** | CNPG operator, ZFS pools, MinIO | PostgreSQL, block storage, object storage |
| **GitOps** | Flux (multi-source) | Infrastructure reconciliation |
| **Virtualization** | KubeVirt, vCluster operator | VM lifecycle, tenant isolation |
| **Security** | cert-manager, Let's Encrypt | TLS certificate automation |
| **DNS** | CoreDNS | Internal + external resolution |

## Shared Services (AI / Data Layer)

In addition to core infrastructure, this repo provides shared AI and data services consumed by all tenants:

| Service | Namespace | Port | Purpose |
|---------|-----------|------|---------|
| **LiteLLM** | `litellm` | 4000 | Unified AI gateway (Claude, Ollama, OpenAI behind one API) |
| **ChromaDB** | `chromadb` | 8000 | Vector database for semantic search and embeddings |
| **Ollama** | `ollama` | 11434 | Local LLM inference on GPU nodes |
| **MCP Registry** | `mcp-registry` | 3000 | Dynamic MCP server discovery and client config generation |

### MCP Registry

The MCP Registry provides automatic discovery for Model Context Protocol servers running anywhere in the cluster. MCP servers register via:

1. **K8s labels** (automatic) — add `mcp.server/enabled: "true"` to any Service
2. **HTTP API** (manual) — `POST /api/v1/register`

Clients get auto-generated config:
```bash
# Generate Claude Code MCP settings
curl http://mcp-registry.mcp-registry.svc:3000/api/v1/config/claude-code
```

## What this does NOT manage

- Open Platform services (Forgejo, Woodpecker, etc.) — OP deploys itself
- Application workloads — managed by OP's CI/CD
- Tenant vClusters — managed by OP's provisioner

## Architecture

```
Host Cluster (this repo)
├── Infrastructure (always running)
│   ├── Traefik       → routes *.domain for all tenants
│   ├── MetalLB       → assigns VIPs from edge VLAN
│   ├── cert-manager  → Let's Encrypt certificates
│   ├── CNPG operator → PostgreSQL lifecycle
│   ├── Flux          → multi-source GitOps
│   ├── vCluster      → tenant isolation
│   ├── CoreDNS       → DNS resolution
│   └── KubeVirt      → Windows VM lifecycle
│
├── vCluster: open-platform (deployed by OP)
│   └── Forgejo, Woodpecker, Headlamp, MinIO, Apps
│
├── vCluster: ai-services (optional)
│   └── ChromaDB, Ollama, data pipelines
│
└── vCluster: tenant-N (optional, via OP provisioner)
    └── Customer workloads
```

## Quick Start

### 1. Configure your site

```bash
cp site-config.nix.example site-config.nix
# Edit with your IPs, VLANs, node names, SSH keys
```

### 2. Install first node

```bash
# Boot NixOS minimal ISO via iDRAC/IPMI
# See INSTALL.md for step-by-step
nixos-install --no-root-passwd
reboot
```

### 3. Join additional nodes

```bash
# PXE boot (automatic) or manual install
# Each node gets its own node-config.nix
```

### 4. Deploy infrastructure services

```bash
# On any control-plane node:
kubectl apply -k infrastructure/
# Or let Flux manage it (recommended):
flux bootstrap git --url=https://your-git/infra --path=infrastructure
```

### 5. Deploy Open Platform

```bash
# In the open-platform repo:
# open-platform.yaml:
#   infrastructure:
#     mode: external
make deploy
```

## Network Design

```
Internet
   │
   ▼
Firewall (L3 gateway, all inter-VLAN routing)
   │
   ├── VLAN 100 (10.0.0.0/20)    K8s Node Network (1G management)
   ├── VLAN 101 (10.0.16.0/20)   K8s Edge / MetalLB VIPs
   ├── VLAN 102 (10.0.32.0/20)   Storage Fabric (10G east-west, no firewall)
   ├── VLAN 103 (10.0.48.0/20)   Tunnel Endpoints (WireGuard)
   ├── VLAN 105 (10.0.64.0/20)   Bare-Metal Provisioning (PXE)
   └── VLAN 900 (10.0.254.0/24)  Live Migration (10G, no firewall)
```

### Traffic flow (external → service)

```
Internet → Public IP → Firewall DNAT → MetalLB VIP (VLAN 101)
→ connmark routing → Traefik → vCluster Ingress → service
Response → connmark restore → VLAN 101 → Firewall → Internet
```

## Node Configuration

Each node is configured via a `node-config.nix` file:

```nix
{
  hostname = "node-1";
  hostId = "abc12345";
  primaryInterface = "eno1";
  primaryAddress = "10.0.0.10/20";

  # 10G storage fabric (optional)
  enable10g = true;
  sfpInterfaces = [ "enp5s0f0" "enp5s0f1" ];
  storageAddress = "10.0.32.10/20";

  # K3s role
  k3sRole = "server";  # "server" (control-plane + etcd) or "agent"

  # Features
  enableEdge = true;      # MetalLB + connmark routing
  enableKvm = false;      # KubeVirt / libvirt
  enableGpu = false;      # NVIDIA passthrough
}
```

See `hosts/worker/node-config.nix` for the full template with all options.

## Documentation

| Doc | Purpose |
|-----|---------|
| [INSTALL.md](INSTALL.md) | Step-by-step bare-metal installation |
| [NETWORK-DESIGN.md](docs/NETWORK-DESIGN.md) | VLAN architecture and traffic flows |
| [LESSONS-LEARNED.md](docs/LESSONS-LEARNED.md) | Production gotchas and fixes |
| [docs/open-platform-deploy.md](docs/open-platform-deploy.md) | Deploying OP with external infrastructure |

## License

MIT
