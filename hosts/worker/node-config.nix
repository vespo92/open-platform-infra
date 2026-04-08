# Node Configuration Template
# Copy this file to /etc/nixos/node-config.nix on each node and customize.
# The worker configuration.nix reads this at eval time.

{
  # ── Identity ────────────────────────────────────────────────────────────────
  hostname = "node-1";
  hostId = "abc12345";  # Generate: head -c4 /dev/urandom | od -A none -t x4 | tr -d ' '

  # ── Network (1G management) ─────────────────────────────────────────────────
  primaryInterface = "eno1";
  primaryAddress = "10.0.0.10/20";
  primaryGateway = "10.0.0.1";

  # ── 10G Storage Fabric (optional) ──────────────────────────────────────────
  # Set enable10g = true if this node has SFP+ NICs connected to a 10G switch.
  # Bond mode: balance-xor with layer3+4 hash (compatible with static LAG on MikroTik/Mellanox).
  enable10g = false;
  sfpInterfaces = [ "enp5s0f0" "enp5s0f1" ];  # Two SFP+ ports for 20G LACP/LAG
  storageAddress = "10.0.32.10/20";             # VLAN 102
  migrationAddress = "10.0.254.10/24";          # VLAN 900 (live migration)

  # ── k0s ─────────────────────────────────────────────────────────────────────
  k0sRole = "controller+worker";                 # "controller+worker" (control-plane + workloads) or "worker"
  k0sTokenFile = "";                             # Join token path; empty = init controller (first node)
  # For joining nodes, set: k0sTokenFile = "/etc/k0s/join-token";
  # Generate tokens on the init controller:
  #   k0s token create --role=controller > controller-token
  #   k0s token create --role=worker > worker-token

  # ── Edge Networking (optional, for MetalLB + external ingress) ──────────────
  # Enable if this node participates in MetalLB L2 advertisement
  # and needs connmark routing for asymmetric firewall traversal.
  enableEdge = false;
  edgeInterface = "eno3";           # NIC connected to edge VLAN switch
  edgeAddress = "10.0.16.10/20";    # VLAN 101
  tunnelAddress = "10.0.48.10/20";  # VLAN 103

  # ── Windows VM Bridge (optional) ───────────────────────────────────────────
  # Enable if this node runs KubeVirt VMs that need bridged access to
  # legacy VLANs (e.g., Active Directory on VLAN 355).
  enableWindowsBridge = false;
  bridgeInterface = "eno2";

  # ── KVM / Virtualization (optional) ────────────────────────────────────────
  enableKvm = false;

  # ── GPU (optional) ─────────────────────────────────────────────────────────
  enableGpu = false;
  # gpuType = "nvidia";  # Future: AMD ROCm support

  # ── ZFS Storage (optional) ─────────────────────────────────────────────────
  enableZfs = true;
  zfsPools = [ "tank" ];  # Pool names (must be created manually before first boot)

  # ── Hardware Classification (optional) ─────────────────────────────────────
  # Optional workload class hint. If unset, the hardware-discovery DaemonSet
  # auto-classifies based on detected hardware (ECC, GPU, cores, RAM).
  # Valid values: "database", "gpu", "compute", "general"
  # nodeClass = "general";
}
