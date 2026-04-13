# Pepr Policy Engine — Adoption Roadmap

> "Slow and steady wins the race." Every phase starts in **audit mode** (log-only)
> before graduating to **enforce mode** (block violations).

## Architecture

```
                    ┌──────────────────────────────┐
                    │     Kubernetes API Server     │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │   Pepr Admission Controller   │
                    │   (MutatingWebhookConfig +    │
                    │    ValidatingWebhookConfig)   │
                    └──────────┬───────────────────┘
                               │
              ┌────────────────┼────────────────────┐
              │                │                     │
    ┌─────────▼──────┐ ┌──────▼───────┐  ┌─────────▼────────┐
    │  Phase 1       │ │  Phase 2     │  │  Phase 3         │
    │  Labels        │ │  Security    │  │  Resources       │
    │  (Validate)    │ │  (Mut+Val)   │  │  (Mut+Val)       │
    └────────────────┘ └──────────────┘  └──────────────────┘
              │
    ┌─────────▼──────┐
    │  Phase 4       │
    │  Namespace     │
    │  (Mut+Watch)   │
    └────────────────┘
```

## Ignored Namespaces (Global)

These namespaces are always exempt from Pepr policies:
- `kube-system`, `kube-public`, `kube-node-lease`
- `pepr-system` (self)
- `flux-system` (GitOps controller)
- `cilium` (CNI)
- `cert-manager` (TLS)

## Phase 1: Label Governance (Week 1-2)

**Goal**: Ensure all workloads and namespaces have standard labels.

| Action | Type | Target | Behavior |
|--------|------|--------|----------|
| Required namespace labels | Validate | Namespace | Audit → Enforce |
| Required workload labels | Validate | Deploy/STS/DS | Audit → Enforce |

**Required namespace labels**:
- `platform.openplatform.io/owner`
- `platform.openplatform.io/environment`

**Required workload labels**:
- `app.kubernetes.io/name`
- `app.kubernetes.io/part-of`
- `app.kubernetes.io/managed-by`

### Steps
1. Deploy Pepr in audit mode (`PEPR_MODE=audit`)
2. Monitor logs: `make audit-log`
3. Fix existing resources that would violate
4. Switch to enforce: set `PEPR_MODE=enforce`

### Rollback
Set `PEPR_MODE=audit` or scale down the Pepr deployment to 0 replicas.

---

## Phase 2: Pod Security Baseline (Week 3-4)

**Goal**: Enforce container security hardening across all pods.

| Action | Type | Target | Behavior |
|--------|------|--------|----------|
| Block privileged containers | Validate | Pod | Audit → Enforce |
| Block host namespaces | Validate | Pod | Audit → Enforce |
| Block root UID 0 | Validate | Pod | Audit → Enforce |
| Drop ALL capabilities | Mutate | Pod | Always active |
| Set readOnlyRootFilesystem | Mutate | Pod | Always active |
| Disable privilege escalation | Mutate | Pod | Always active |

### Steps
1. Enable Phase 2 capability in `pepr.ts`
2. Run in audit mode for 1 week
3. Review audit logs for legitimate privileged workloads
4. Add exemptions as needed (node-exporter, Cilium agent, etc.)
5. Switch to enforce

### Known Exemptions Needed
- `cilium-agent` (DaemonSet) — needs host networking + privileged
- `node-exporter` — needs host PID/network for metrics
- `hardware-discovery` — needs host access for node labeling

---

## Phase 3: Resource Governance (Week 5-6)

**Goal**: Every container must declare CPU/memory requests and limits.

| Action | Type | Target | Behavior |
|--------|------|--------|----------|
| Require resource definitions | Validate | Pod | Audit → Enforce |
| Inject default resources | Mutate | Pod | Always active |

**Default injection** (when no resources specified):
- Requests: 50m CPU, 64Mi memory
- Limits: 500m CPU, 256Mi memory

### Steps
1. Enable Phase 3 capability
2. Audit for 1 week to find bare pods
3. Update HelmRelease values to include explicit resources
4. Switch to enforce

---

## Phase 4: Namespace Automation (Week 7-8)

**Goal**: New namespaces auto-receive security defaults.

| Action | Type | Target | Behavior |
|--------|------|--------|----------|
| Inject default labels | Mutate | Namespace | Always active |
| Create ResourceQuota | Watch | Namespace | Auto-create |
| Create LimitRange | Watch | Namespace | Auto-create |

**Default ResourceQuota**:
- 4 CPU requests / 8 CPU limits
- 8Gi memory requests / 16Gi memory limits
- 50 pods, 20 services, 10 PVCs

### Steps
1. Enable Phase 4 capability
2. Test by creating a scratch namespace
3. Verify quota and limits are auto-applied
4. Monitor for issues with existing namespace workflows

---

## Deployment Workflow

### First-Time Setup
```bash
cd infrastructure/pepr
make install
make dev                  # Test against local/dev cluster first
```

### Production Deployment
```bash
# Build generates K8s manifests in dist/
make build

# Deploy to cluster (creates webhooks + controller)
make deploy

# Or let Flux handle it via the kustomization
git push  # Flux reconciles automatically
```

### Switching from Audit to Enforce
Update `package.json`:
```json
"env": {
  "PEPR_MODE": "enforce"
}
```
Then rebuild and redeploy.

### Emergency Rollback
```bash
# Option 1: Scale to zero (instant, keeps config)
kubectl scale deployment -n pepr-system pepr-open-platform-policy --replicas=0

# Option 2: Delete webhooks (removes all admission control)
kubectl delete mutatingwebhookconfiguration pepr-open-platform-policy
kubectl delete validatingwebhookconfiguration pepr-open-platform-policy

# Option 3: Switch back to audit mode
# Edit package.json PEPR_MODE=audit, rebuild, redeploy
```

## Monitoring

Pepr logs are structured JSON — pipe to Loki via Alloy for dashboarding.

```bash
# Tail live audit logs
make audit-log

# Search for denials
kubectl logs -n pepr-system -l app=pepr-open-platform-policy | grep DENY

# Search for mutations
kubectl logs -n pepr-system -l app=pepr-open-platform-policy | grep MUTATE
```

### Grafana Dashboard (Future)
- Admission requests per second
- Deny vs Approve ratio
- Mutation frequency by capability
- Webhook latency (p50/p95/p99)

## Future Phases (Post-Adoption)

- **Phase 5**: Cilium NetworkPolicy generation — auto-create least-privilege network policies per namespace
- **Phase 6**: Image provenance — validate container image signatures and registries
- **Phase 7**: Cost governance — enforce resource ceilings per team/namespace
- **Phase 8**: Compliance reporting — generate SOC2/CIS benchmark reports from policy state
