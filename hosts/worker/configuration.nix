# Generic K3s Node — Dynamic Configuration
#
# Universal NixOS config for all K3s nodes (control-plane and agents).
# The k3sRole in node-config.nix determines the node's role.
#
# Node-specific values come from /etc/nixos/node-config.nix.
# PXE auto-installer drops that file; everything else is identical.
#
# To deploy a new node:
#   1. PXE boot (or manual install with NixOS ISO)
#   2. Place /etc/nixos/node-config.nix with node-specific values
#   3. Place /etc/k3s-token with the cluster join token
#   4. nixos-rebuild switch --no-flake
{ config, pkgs, lib, ... }:

let
  # ── Load node-specific config ──────────────────────────────
  nodeConfigPath = /etc/nixos/node-config.nix;
  node =
    if builtins.pathExists nodeConfigPath
    then import nodeConfigPath
    else {
      # Sane defaults for first boot / PXE environment
      hostname = "k3s-node";
      hostId = "abcd1234";
      primaryInterface = "eno1";
      primaryAddress = "10.0.0.99/20";
      primaryGateway = "10.0.0.1";
      enable10g = false;
      sfpInterfaces = [ "enp5s0f0" "enp5s0f1" ];
      storageAddress = "10.0.32.99/20";
      migrationAddress = "10.0.254.99/24";
      k3sRole = "agent";
      k3sServerAddr = "https://10.0.0.10:6443";
      k3sTokenFile = "/etc/k3s-token";
      enableEdge = false;
      edgeInterface = "eno3";
      edgeAddress = "10.0.16.99/20";
      tunnelAddress = "10.0.48.99/20";
      enableWindowsBridge = false;
      bridgeInterface = "eno2";
    };

  # Helper: optional attribute with default
  nodeAttr = name: default:
    if builtins.hasAttr name node then node.${name} else default;

  # Strip CIDR suffix from IP (e.g., "10.0.0.10/20" -> "10.0.0.10")
  nodeIP = builtins.head (builtins.split "/" node.primaryAddress);

in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware-classification.nix
  ];

  # ═══════════════════════════════════════════════════════════
  # Identity
  # ═══════════════════════════════════════════════════════════

  system.stateVersion = "24.11";
  nixpkgs.hostPlatform = "x86_64-linux";

  networking.hostName = lib.mkForce node.hostname;
  networking.hostId = lib.mkForce node.hostId;

  # ═══════════════════════════════════════════════════════════
  # Boot
  # ═══════════════════════════════════════════════════════════

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "sd_mod" "sr_mod"
    "usb_storage" "uas" "megaraid_sas"
    "tg3" "bnx2x" "igb" "ixgbe" "e1000e" "i40e"
  ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" "bonding" "8021q" ];

  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" "boot.shell_on_fail" ]
    ++ lib.optionals (nodeAttr "enableKvm" false) [ "hugepagesz=2M" "hugepages=4096" ];

  # ZFS support (when enableZfs = true in node-config.nix)
  boot.supportedFilesystems = lib.mkIf (nodeAttr "enableZfs" false) [ "zfs" ];
  boot.zfs.extraPools = lib.mkIf (nodeAttr "enableZfs" false)
    (nodeAttr "zfsPools" []);
  services.zfs.autoScrub = lib.mkIf (nodeAttr "enableZfs" false) {
    enable = true;
    interval = "monthly";
  };

  # ═══════════════════════════════════════════════════════════
  # Network — Primary (1G management NIC)
  # ═══════════════════════════════════════════════════════════

  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.wait-online.anyInterface = true;

  # ═══════════════════════════════════════════════════════════
  # Network — 10G Static Bond (east-west storage fabric)
  # Uses balance-xor with layer3+4 hash for compatibility with
  # switches using static LAG (no LACP required).
  # Only active when enable10g = true in node-config.nix.
  # ═══════════════════════════════════════════════════════════

  systemd.network.netdevs = lib.mkMerge [
    # Bond interface
    (lib.mkIf node.enable10g {
      "10-bond0" = {
        netdevConfig = {
          Name = "bond0";
          Kind = "bond";
          MTUBytes = "9000";
        };
        bondConfig = {
          Mode = "balance-xor";
          TransmitHashPolicy = "layer3+4";
          MIIMonitorSec = "0.1";
        };
      };
    })

    # VLAN 102 — Storage Fabric (east-west, no firewall)
    (lib.mkIf node.enable10g {
      "30-vlan102" = {
        netdevConfig = { Name = "vlan102"; Kind = "vlan"; MTUBytes = "9000"; };
        vlanConfig.Id = 102;
      };
    })

    # VLAN 900 — Live Migration
    (lib.mkIf node.enable10g {
      "30-vlan900" = {
        netdevConfig = { Name = "vlan900"; Kind = "vlan"; MTUBytes = "9000"; };
        vlanConfig.Id = 900;
      };
    })

    # Edge VLANs (for MetalLB / external ingress)
    (lib.mkIf (nodeAttr "enableEdge" false) {
      "30-vlan101" = {
        netdevConfig = { Name = "vlan101"; Kind = "vlan"; };
        vlanConfig.Id = 101;
      };
      "30-vlan103" = {
        netdevConfig = { Name = "vlan103"; Kind = "vlan"; };
        vlanConfig.Id = 103;
      };
    })
  ];

  systemd.network.networks = lib.mkMerge [
    # ── Primary NIC (1G management) ──
    {
      "10-primary" = {
        matchConfig.Name = node.primaryInterface;
        networkConfig.DHCP = "no";
        address = [ node.primaryAddress ];
        routes = [ { Gateway = node.primaryGateway; } ];
        dns = [ "1.1.1.1" "8.8.8.8" ];
      };
    }

    # ── 10G Bond Members ──
    (lib.mkIf node.enable10g {
      "20-sfp0" = {
        matchConfig.Name = builtins.elemAt node.sfpInterfaces 0;
        networkConfig = { Bond = "bond0"; DHCP = "no"; };
        linkConfig.MTUBytes = "9000";
      };
      "20-sfp1" = {
        matchConfig.Name = builtins.elemAt node.sfpInterfaces 1;
        networkConfig = { Bond = "bond0"; DHCP = "no"; };
        linkConfig.MTUBytes = "9000";
      };
    })

    # ── Bond Parent (carries tagged VLANs, no IP) ──
    (lib.mkIf node.enable10g {
      "20-bond0" = {
        matchConfig.Name = "bond0";
        networkConfig.DHCP = "no";
        linkConfig.MTUBytes = "9000";
        vlan = [ "vlan102" "vlan900" ];
      };
    })

    # ── VLAN 102 — Storage ──
    (lib.mkIf node.enable10g {
      "30-vlan102" = {
        matchConfig.Name = "vlan102";
        networkConfig.DHCP = "no";
        address = [ node.storageAddress ];
        linkConfig.MTUBytes = "9000";
      };
    })

    # ── VLAN 900 — Live Migration ──
    (lib.mkIf node.enable10g {
      "30-vlan900" = {
        matchConfig.Name = "vlan900";
        networkConfig.DHCP = "no";
        address = [ node.migrationAddress ];
        linkConfig.MTUBytes = "9000";
      };
    })

    # ── Edge NIC (VLANs 101, 103 for MetalLB) ──
    (lib.mkIf (nodeAttr "enableEdge" false) {
      "20-edge" = {
        matchConfig.Name = node.edgeInterface;
        networkConfig.DHCP = "no";
        vlan = [ "vlan101" "vlan103" ];
      };
      "30-vlan101" = {
        matchConfig.Name = "vlan101";
        networkConfig.DHCP = "no";
        address = [ node.edgeAddress ];
        # Connmark policy routing for MetalLB through stateful firewall
        routingPolicyRules = [
          # Pod/service CIDRs use main table (MUST be before fwmark rule)
          { To = "10.42.0.0/16"; Table = 254; Priority = 40; }
          { To = "10.43.0.0/16"; Table = 254; Priority = 40; }
          # Marked packets (connmark restored) route via edge VLAN
          { FirewallMark = 101; Table = 101; Priority = 50; }
          # Source-based: locally-originated from edge subnet
          { From = "10.0.16.0/20"; Table = 101; Priority = 100; }
        ];
        routes = [
          { Gateway = "10.0.16.1"; Table = 101; }
        ];
      };
      "30-vlan103" = {
        matchConfig.Name = "vlan103";
        networkConfig.DHCP = "no";
        address = [ node.tunnelAddress ];
      };
    })
  ];

  # ═══════════════════════════════════════════════════════════
  # K3s
  # ═══════════════════════════════════════════════════════════

  services.k3s = {
    enable = true;
    role = node.k3sRole;
    tokenFile = node.k3sTokenFile;
  } // lib.optionalAttrs (node.k3sServerAddr != "") {
    serverAddr = node.k3sServerAddr;
    extraFlags = [
      "--disable" "servicelb"  # Use MetalLB instead
    ]
    # ── Hardware-derived node labels ──
    # These propagate node-config.nix capabilities into Kubernetes at registration.
    # The hardware-discovery DaemonSet adds runtime-detected labels (ECC, NVMe, etc.)
    # on top of these static labels.
    ++ [ "--node-label" "platform.openplatform.io/10g=${lib.boolToString node.enable10g}" ]
    ++ [ "--node-label" "platform.openplatform.io/edge=${lib.boolToString (nodeAttr "enableEdge" false)}" ]
    ++ [ "--node-label" "platform.openplatform.io/kvm=${lib.boolToString (nodeAttr "enableKvm" false)}" ]
    ++ [ "--node-label" "platform.openplatform.io/gpu.enabled=${lib.boolToString (nodeAttr "enableGpu" false)}" ]
    ++ [ "--node-label" "platform.openplatform.io/zfs=${lib.boolToString (nodeAttr "enableZfs" false)}" ]
    ++ [ "--node-label" "platform.openplatform.io/role=${node.k3sRole}" ]
    ++ lib.optionals (nodeAttr "nodeClass" null != null) [
      "--node-label" "platform.openplatform.io/node-class=${node.nodeClass}"
    ]
    # ── GPU taint at registration ──
    # Ensures GPU nodes are protected from the moment they join the cluster,
    # before the hardware-discovery DaemonSet runs.
    ++ lib.optionals (nodeAttr "enableGpu" false) [
      "--node-taint" "gpu=true:NoSchedule"
    ];
  };

  # ═══════════════════════════════════════════════════════════
  # Users — set SSH keys in node-config.nix
  # ═══════════════════════════════════════════════════════════

  users.mutableUsers = false;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ] ++ lib.optionals (nodeAttr "enableKvm" false) [ "libvirtd" ];
    # Add your SSH keys here or in node-config.nix
    openssh.authorizedKeys.keys = nodeAttr "sshKeys" [];
  };

  users.users.root = {
    openssh.authorizedKeys.keys = nodeAttr "sshKeys" [];
  };

  security.sudo.wheelNeedsPassword = false;

  # ═══════════════════════════════════════════════════════════
  # SSH
  # ═══════════════════════════════════════════════════════════

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
    openFirewall = true;
  };

  # ═══════════════════════════════════════════════════════════
  # Firewall
  # ═══════════════════════════════════════════════════════════

  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [
      2379 2380    # etcd HA (server nodes)
      10250        # kubelet
      6443         # K8s API
    ] ++ lib.optionals (nodeAttr "enableEdge" false) [
      80 443       # Traefik (MetalLB edge)
      7946 7472    # MetalLB memberlist
    ];
    allowedUDPPorts = [
      8472         # flannel VXLAN (cross-node pod networking)
    ] ++ lib.optionals (nodeAttr "enableEdge" false) [
      7946 7472    # MetalLB memberlist
    ];
    trustedInterfaces = [ "cni0" "flannel.1" ]
      ++ lib.optionals (nodeAttr "enableKvm" false) [ "br-vms" "virbr0" ];
  };

  # Edge: loose rpfilter + connmark for MetalLB through stateful firewall
  networking.firewall.checkReversePath = lib.mkIf (nodeAttr "enableEdge" false) "loose";

  boot.kernel.sysctl = lib.mkIf (nodeAttr "enableEdge" false) {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };

  # Connmark: mark incoming edge traffic, restore on response
  networking.firewall.extraCommands = lib.mkIf (nodeAttr "enableEdge" false) (lib.mkAfter ''
    iptables -t mangle -I PREROUTING 1 -i vlan101 -d 10.0.16.0/20 -j MARK --set-xmark 0x65/0x65
    iptables -t mangle -I PREROUTING 2 -i vlan101 -d 10.0.16.0/20 -j CONNMARK --save-mark
    iptables -t mangle -I PREROUTING 3 -m connmark --mark 0x65 ! -d 10.42.0.0/16 -j CONNMARK --restore-mark
    iptables -t mangle -I OUTPUT 1 -m connmark --mark 0x65 -j CONNMARK --restore-mark
    iptables -I FORWARD 1 -m conntrack --ctstate DNAT -j ACCEPT
  '');

  networking.firewall.extraStopCommands = lib.mkIf (nodeAttr "enableEdge" false) ''
    iptables -t mangle -D PREROUTING -i vlan101 -d 10.0.16.0/20 -j MARK --set-xmark 0x65/0x65 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i vlan101 -d 10.0.16.0/20 -j CONNMARK --save-mark 2>/dev/null || true
    iptables -t mangle -D PREROUTING -m connmark --mark 0x65 ! -d 10.42.0.0/16 -j CONNMARK --restore-mark 2>/dev/null || true
    iptables -t mangle -D OUTPUT -m connmark --mark 0x65 -j CONNMARK --restore-mark 2>/dev/null || true
    iptables -D FORWARD -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || true
  '';

  # Storage fabric + migration ports
  networking.firewall.interfaces = lib.mkIf node.enable10g {
    "vlan102" = {
      allowedTCPPorts = [ 2049 111 ];  # NFS + portmapper
      allowedUDPPorts = [ 2049 111 ];
    };
    "vlan900" = {
      allowedTCPPortRanges = [
        { from = 49152; to = 49215; }  # libvirt live migration
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════
  # KVM / Libvirt / Cockpit (when enableKvm = true)
  # ═══════════════════════════════════════════════════════════

  virtualisation.libvirtd = lib.mkIf (nodeAttr "enableKvm" false) {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
    onBoot = "start";
    onShutdown = "shutdown";
    allowedBridges = [ "br-vms" "virbr0" ];
  };

  services.cockpit = lib.mkIf (nodeAttr "enableKvm" false) {
    enable = true;
    port = 9090;
    settings = {
      WebService = {
        AllowUnencrypted = true;
        Origins = lib.mkForce "http://${nodeIP}:9090 https://${nodeIP}:9090";
      };
    };
  };

  # VM bridge for legacy VLANs
  networking.bridges = lib.mkIf (nodeAttr "enableKvm" false && nodeAttr "enableWindowsBridge" false) {
    "br-vms" = {
      interfaces = [ (nodeAttr "bridgeInterface" "eno2") ];
    };
  };

  # ═══════════════════════════════════════════════════════════
  # Packages
  # ═══════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    vim git curl wget htop tmux jq
    pciutils usbutils smartmontools nvme-cli
    ethtool iproute2 tcpdump iperf3
    traceroute lsof
  ] ++ lib.optionals (nodeAttr "enableKvm" false) [
    pkgs.qemu_kvm
    pkgs.virt-manager
    pkgs.virtiofsd
    pkgs.swtpm
    pkgs.cni-plugins
  ];

  # ═══════════════════════════════════════════════════════════
  # Nix Settings
  # ═══════════════════════════════════════════════════════════

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "admin" ];

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
}
