# Lessons Learned

Production gotchas hit while running this stack on real hardware. Each
entry is a thing that broke, why it broke, and what's now in the repo
to keep it from breaking again.

## 1. Cilium renames Multus CNI config (KubeVirt VMs only)

**Symptom**: KubeVirt VMs with bridged network interfaces fail to start
with `pod link is missing`. Pods that don't use Multus are unaffected.

**Cause**: Cilium 1.16.x's CNI install rewrites `/etc/cni/net.d` and
renames `00-multus.conf` → `00-multus.conf.cilium_bak` on every agent
restart, regardless of `cni.exclusive: false`. kubelet then reads
`05-cilium.conflist` directly and skips Multus entirely.

**Fix**: Defense-in-depth self-heal in `hosts/worker/configuration.nix`:

1. `environment.etc` ships a canonical multus-shim config as a fallback.
2. `systemd.path` watches `/etc/cni/net.d` via inotify and restores
   `00-multus.conf` from `.cilium_bak` (or the canonical) on rename.
3. `systemd.timer` runs the same oneshot every 60s as backup.

The service is idempotent — if `00-multus.conf` already exists it's a
no-op. Opt in with `enableMultusSelfHeal = true` in `node-config.nix`.

## 2. k3s helm-controller cascade-uninstalls Cilium

**Symptom**: Deleting a stale `helmchart.helm.cattle.io` resource
triggers a `helm uninstall` of the underlying release. If that release
is Cilium, the entire cluster network drops in seconds.

**Cause**: k3s ships an in-tree Wrangler helm-controller that adds a
`wrangler.cattle.io/on-helm-chart-remove` finalizer to every HelmChart
CR. The finalizer's removal handler runs `helm uninstall` synchronously.

**Fix**: `--disable helm-controller` is passed to k3s in
`hosts/worker/configuration.nix`. Flux is the sole helm manager. Do not
remove the flag unless you have removed Flux.

## 3. Cilium moves the local lookup rule to priority 100

**Symptom**: After Cilium agent startup, the node loses the ability to
deliver packets addressed to its own IPs. kubelet → apiserver fails,
host-network pods can't reach LoadBalancer VIPs.

**Cause**: Cilium re-creates `from all lookup local` at priority 100
instead of the kernel default of 0. Higher-priority rules then override
local delivery.

**Fix**: `fix-local-rule` systemd timer in `hosts/worker/configuration.nix`
runs every 60s, ensures pref 0 exists, and only then deletes the
misplaced pref 100 entry. Two-step idempotent — a partial failure
cannot leave the routing table without a local lookup at all.

## 4. Stranded pod IPs after CNI migration

**Symptom**: After switching from Flannel to Cilium on a running
cluster, existing pods are unreachable. Their IPs come from the old
Flannel allocation that Cilium's BPF maps don't know about.

**Cause**: Pods keep their assigned IP for life. CNI replacement only
affects newly-scheduled pods.

**Fix**: After Cilium agents are healthy on every node, delete every
non-DaemonSet pod so the scheduler reassigns them with Cilium-allocated
IPs:

```bash
kubectl get pods -A -o wide --no-headers | \
  awk '$7 !~ /^10\.42\./ {print $1, $2}' | \
  xargs -L1 kubectl delete pod -n
```

DaemonSets are restart-in-place and pick up the new CNI automatically.

## 5. MTU mismatch destroys throughput long before it breaks anything

**Symptom**: Pod-to-pod throughput peaks at 4–5 Gbps on a 10G fabric.
TCP retransmits visible in `ss -tin`. Things still work, just slowly.

**Cause**: Cilium's `MTU` value didn't match the underlying interface
MTU. Native routing doesn't add encap overhead, but a mismatched MTU
silently drops the largest frames at the boundary.

**Fix**: Match Cilium's `MTU` to the fabric MTU minus a small headroom.

| Fabric MTU | Cilium `MTU` |
|------------|--------------|
| 1500 | `1500` |
| 9000 | `8950` |

Then verify every NIC, bond, and VLAN on the pod path is set to the
fabric MTU in `node-config.nix`. systemd-networkd applies it via
`linkConfig.MTUBytes`.

After the fix the same path went from ~4.5 Gbps → ~9.0 Gbps.

## 6. ZFS auto-import via boot.zfs.extraPools can hang boot

**Symptom**: New node hangs at boot with `Importing ZFS pool tank...`
forever.

**Cause**: `boot.zfs.extraPools = [ "tank" ]` blocks boot until the
pool exists. On a fresh install the pool isn't created yet.

**Fix**: Create the pool manually first, then add it to the list:

```bash
# Boot the installer ISO, then:
zpool create -o ashift=12 tank /dev/disk/by-id/...
# Now add `enableZfs = true; zfsPools = [ "tank" ];` to node-config.nix
nixos-rebuild switch
```

## 7. MetalLB L2 only fails over, doesn't load balance

**Symptom**: Traefik VIP is fast but only lands on one node at a time.
Adding more nodes doesn't increase ingress capacity.

**Cause**: L2 advertisement uses gratuitous ARP — exactly one speaker
owns each VIP at any moment. The other speakers stand by.

**Fix**: Use BGP instead. Most upstream routers (OPNsense, pfSense,
Palo Alto, MikroTik, Cisco) install ECMP routes when multiple speakers
advertise the same /32. Combined with `externalTrafficPolicy: Local`
on the LoadBalancer Service you get true horizontal ingress scaling
with no SNAT.

The MetalLB HelmRelease in this repo runs in FRR mode out of the box,
so adding BGP is just uncommenting the `BGPPeer` + `BGPAdvertisement`
in `infrastructure/metallb/config.yaml`.
