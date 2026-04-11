# Cilium

Cilium is the CNI for Open Platform Infrastructure. It replaces both
Flannel (pod networking) and kube-proxy (service load balancing) with a
single eBPF-based data plane.

## What you get

| Feature | Mechanism | Why it matters |
|---------|-----------|----------------|
| **Pod networking** | Native L3 routing on the underlying fabric, no VXLAN | Line-rate pod-to-pod throughput. ~9 Gbps on a 10G fabric with jumbo frames vs. ~900 Mbps for VXLAN-on-1G. |
| **Service load balancing** | BPF cgroup-connect hook (`kubeProxyReplacement: true`) | O(1) Service VIP lookup. No iptables KUBE-SVC-* chains. Drop-in replacement for kube-proxy. |
| **Network policy** | Cilium NetworkPolicy + L7 (HTTP/gRPC/Kafka) | Identity-aware, not IP-aware — survives pod restarts. |
| **Observability** | Hubble + Hubble Relay | Flow logs, drop reasons, DNS visibility, service map. |
| **Auto node routes** | `autoDirectNodeRoutes: true` | Add a node, Cilium learns its PodCIDR and installs routes on every other node. No manual route table management. |

## Architecture

```
                    apiserver (10.0.0.10:6443)
                          ▲
                          │ k8sServiceHost (Cilium bootstrap path)
                          │
   ┌──────────────────────┼──────────────────────┐
   ▼                      ▼                      ▼
┌────────┐            ┌────────┐            ┌────────┐
│ node-1 │            │ node-2 │            │ node-3 │
│        │            │        │            │        │
│ pod A  │◄──native──►│ pod B  │◄──native──►│ pod C  │
│ 10.42  │            │ 10.42  │            │ 10.42  │
│ .0./24 │            │ .1./24 │            │ .2./24 │
└────────┘            └────────┘            └────────┘
     │                     │                     │
     └─────────── L2 fabric (vlanXXX) ───────────┘
              autoDirectNodeRoutes installs:
                10.42.1.0/24 via 10.0.X.11
                10.42.2.0/24 via 10.0.X.12
```

The fabric Cilium routes over is whatever interface the node uses to
reach its peers — by default the primary management NIC (`eno1`-style,
1G). To get the 10G performance numbers, point pod traffic at a jumbo-MTU
fabric and bump `MTU` in `helmrelease.yaml` to 8950. See the **Tuning**
section below.

## Performance reference

These numbers come from a 3-node x86_64 cluster (Dell R430 + EPYC) with
the Cilium config in this directory. Use them as ballpark, not gospel.

| Path | Throughput | Notes |
|------|------------|-------|
| Raw fabric host-to-host (10G + MTU 9000) | ~9.85 Gbps | iperf3 ceiling |
| Pod-to-pod, native routing, 10G + MTU 8950 | **~9.03 Gbps** | 92% of raw — production target |
| Pod-to-pod, native routing, 10G + MTU 1500 | 4–5 Gbps | TCP retransmits eat the rest |
| Pod-to-pod, VXLAN over 1G management NIC | ~900 Mbps | Link-bound, what you get with default Flannel |

The big lesson: **MTU and routing mode matter more than the CNI choice
itself**. Native routing + jumbo frames is the entire performance story.

## Tuning

### Match the underlying fabric MTU

Cilium's `MTU` value should be the fabric MTU minus a small headroom.

| Fabric MTU | Cilium `MTU` |
|------------|--------------|
| 1500 (default Ethernet) | `1500` |
| 9000 (jumbo) | `8950` |

Edit `helmrelease.yaml`:

```yaml
values:
  MTU: 8950
```

Then make sure every NIC, bond, and VLAN on the pod path is configured
for MTU 9000 in your `node-config.nix`. NixOS systemd-networkd applies
this via `linkConfig.MTUBytes`.

### Pin the pod fabric

By default Cilium will use whichever interface the node uses to reach
the apiserver. If you have a dedicated 10G east-west fabric on its own
VLAN, pin Cilium to it explicitly:

```yaml
values:
  devices: vlan102+
```

The `+` is a glob — `vlan102+` matches `vlan102` and any sub-interface.

### Match the cluster CIDR

If you change `--cluster-cidr` in your k3s args (e.g. to use `10.244.0.0/16`),
update `ipv4NativeRoutingCIDR` in `helmrelease.yaml` to match.

## kube-proxy replacement

This profile sets `kubeProxyReplacement: true`. For this to actually
work, k3s must be started with `--disable-kube-proxy`. The default
`hosts/worker/configuration.nix` does this.

The `k8sServiceHost` value (`10.0.0.10`) is the bootstrap path Cilium
uses to reach the apiserver before it has programmed Service routing
for itself. It must point at a real control-plane node IP, not the
`kubernetes` Service VIP. Update it to match your `node-1` primary IP
if you change the default.

## BGP

This profile keeps `bgpControlPlane.enabled: false` and lets MetalLB
(in FRR mode) advertise LoadBalancer VIPs. To switch to Cilium-native
BGP:

1. Flip `bgpControlPlane.enabled: true` here.
2. Disable the MetalLB HelmRelease (`infrastructure/metallb/helmrelease.yaml`).
3. Add `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement`,
   and `CiliumLoadBalancerIPPool` resources in this directory.
4. Update your upstream router with the new ASN/peer pairing.

For most users running a single firewall (OPNsense, pfSense, Palo Alto),
**MetalLB FRR is the simpler default** and supports both L2 and BGP
advertisement out of the box.

## Operational gotchas

These are baked into `hosts/worker/configuration.nix`. Documented here
so you understand what the systemd units are protecting against.

### `fix-local-rule` timer

Cilium moves `from all lookup local` from priority 0 to 100 on startup.
This breaks the node's ability to deliver packets addressed to its own
IPs (kubelet to apiserver, host services to LB VIPs). The
`fix-local-rule.timer` runs every 60s and re-pins it to priority 0.
Idempotent — costs nothing if already correct.

### Multus self-heal (only if you run KubeVirt VMs with bridge nets)

Cilium 1.16.x renames `/etc/cni/net.d/00-multus.conf` to `.cilium_bak`
on every CNI install, even with `cni.exclusive: false`. KubeVirt VMs
that depend on Multus NetworkAttachmentDefinitions then fail to launch
because kubelet skips Multus and goes straight to Cilium.

The `multus-selfheal` systemd path + timer watches `/etc/cni/net.d`
and restores `00-multus.conf` from the `.cilium_bak` (or a canonical
fallback) within 60 seconds. Opt in with `enableMultusSelfHeal = true`
in `node-config.nix`.

### k3s helm-controller cascade

k3s ships an in-tree helm-controller (Wrangler). If you also use Flux,
deleting a stale `helmchart.helm.cattle.io` resource will trigger a
`helm uninstall` of the underlying release — and if that release happens
to be Cilium, the entire cluster network drops. The `worker/configuration.nix`
adds `--disable helm-controller` so Flux is the only helm manager. Do
not remove this flag unless you have removed Flux.

### Stranded pod IPs after migration

If you switch from Flannel to Cilium on a running cluster, existing pods
keep their old Flannel-allocated IPs and become unreachable. Bounce all
non-DaemonSet pods after Cilium is healthy:

```bash
kubectl get pods -A -o wide | grep -v 10.42 | awk '{print $1, $2}' | \
  tail -n +2 | xargs -L1 kubectl delete pod -n
```

## Verification

```bash
# Cilium agents healthy
kubectl -n kube-system get pods -l k8s-app=cilium

# kube-proxy replacement is active
kubectl -n kube-system exec ds/cilium -- cilium status | grep KubeProxyReplacement
# expect: KubeProxyReplacement:    True

# Hubble flows
kubectl -n kube-system exec ds/cilium -- hubble observe --last 20

# Pod-to-pod throughput (run iperf3 server in one pod, client in another)
kubectl run iperf-server --image=networkstatic/iperf3 -- -s
kubectl run iperf-client --image=networkstatic/iperf3 --rm -it -- \
  -c iperf-server.default.svc.cluster.local
```
