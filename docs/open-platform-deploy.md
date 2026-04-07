# Deploying Open Platform on External Infrastructure

After setting up the infrastructure layer with this repo, deploy Open Platform into its own vCluster.

## Prerequisites

Verify infrastructure is running:

```bash
# All infrastructure pods healthy
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
kubectl get pods -n metallb-system
kubectl get pods -n cert-manager
kubectl get pods -n cnpg-system
kubectl get pods -n flux-system

# Or use the OP check script
cd /path/to/open-platform
./scripts/check-infra.sh
```

## Deploy

```bash
cd /path/to/open-platform

# Configure
cat > open-platform.yaml <<EOF
domain: platform.example.com

infrastructure:
  mode: external

network:
  mode: loadbalancer
  traefik_ip: 10.0.16.10
  address_pool: 10.0.16.0/24
  interface: vlan101

tls:
  mode: letsencrypt
  email: admin@example.com
EOF

# Deploy
make deploy
```

## What happens

1. `check-infra.sh` validates Traefik, MetalLB, cert-manager, CNPG, Flux, and vCluster are running
2. A vCluster named "open-platform" is created on the host cluster
3. OP services deploy inside the vCluster (Forgejo, Woodpecker, etc.)
4. Ingress resources sync from vCluster to host Traefik automatically
5. cert-manager issues TLS certificates for `*.platform.example.com`

## Verify

```bash
# OP services running in vCluster
vcluster connect open-platform -- kubectl get pods -A

# Ingress visible on host (synced from vCluster)
kubectl get ingress -A | grep platform.example.com

# Access services
curl -I https://forgejo.platform.example.com
curl -I https://ci.platform.example.com
```

## Lifecycle

| Action | Infrastructure (this repo) | Open Platform |
|--------|---------------------------|---------------|
| Upgrade Traefik | Update HelmRelease, Flux reconciles | No change needed |
| Upgrade OP | No change needed | `make deploy` or push to Forgejo |
| Add tenant | No change needed | OP provisioner creates vCluster |
| Scale nodes | Add node-config.nix, PXE boot | Pods auto-schedule |
| Disaster recovery | Rebuild NixOS from config | `make deploy` (idempotent) |
