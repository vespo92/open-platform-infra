# Auto-Installer for PXE-booted nodes
# Runs automatically on netboot, detects the first available disk,
# partitions it, fetches NixOS config from the provisioning server,
# installs NixOS, sets up Clover if needed (older Dell servers), and reboots.
#
# Flow: PXE boot → NixOS in RAM → this service → disk install → reboot
#
# Safety: Will NOT run if already installed (checks root filesystem type)
#         Will NOT run if booted from a local disk
{ config, pkgs, lib, ... }:

let
  # Provisioning server — must match dhcp-server.nix and pxe-server.nix
  # Override these in your site configuration
  prov = {
    serverIP = "10.0.64.10";   # Customize: your PXE server IP on provisioning VLAN
    httpPort = 9080;
  };
in
{
  environment.systemPackages = with pkgs; [
    nixos-install-tools
    parted dosfstools e2fsprogs
    gnutar gzip curl util-linux
    pciutils usbutils nvme-cli smartmontools jq

    (writeShellScriptBin "manual-install" ''
      echo "Starting manual NixOS install..."
      systemctl start auto-install --no-block
      journalctl -fu auto-install
    '')
  ];

  systemd.services.auto-install = {
    description = "Turnkey Auto-Install to Disk";
    after = [ "network-online.target" "systemd-resolved.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      TimeoutStartSec = "30min";
    };

    path = with pkgs; [
      nixos-install-tools nix parted dosfstools e2fsprogs
      gnutar gzip curl util-linux coreutils bash
      gnugrep gnused gawk findutils iproute2 jq smartmontools
    ];

    script = ''
      #!/usr/bin/env bash
      set -euo pipefail

      LOG="/tmp/install.log"
      exec > >(tee -a "$LOG") 2>&1

      echo ""
      echo "========================================================"
      echo "  Open Platform Infrastructure — Auto-Installer"
      echo "========================================================"
      echo ""
      echo "$(date '+%Y-%m-%d %H:%M:%S') - Auto-install starting..."

      # ── Guard: Only run from netboot (RAM root) ──────────────
      ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
      echo "Root filesystem: $ROOT_FS"

      case "$ROOT_FS" in
        tmpfs|ramfs|overlay|none)
          echo "Running from RAM — proceeding with install"
          ;;
        *)
          echo "Running from disk ($ROOT_FS) — skipping auto-install"
          exit 0
          ;;
      esac

      # ── Detect hardware model ──────────────────────────────
      PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")
      SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "Unknown")
      echo "Hardware: $PRODUCT (Serial: $SERIAL)"

      # Determine if this hardware needs Clover for NVMe boot
      # (Older Dell servers like R430/R530 can't boot NVMe natively)
      NEEDS_CLOVER=false
      case "$PRODUCT" in
        "PowerEdge R430"*|"PowerEdge R530"*|"PowerEdge T430"*)
          NEEDS_CLOVER=true
          echo "  Clover required for NVMe boot"
          ;;
        *)
          echo "  Standard hardware: native NVMe boot expected"
          ;;
      esac

      # ── Detect target disk ──────────────────────────────────
      echo ""
      echo "-- Detecting disks --"

      TARGET_DISK=""

      for pattern in /dev/nvme[0-9]n[0-9] /dev/sd[a-z] /dev/vd[a-z]; do
        for disk in $pattern; do
          [ -b "$disk" ] || continue
          DEVNAME=$(basename "$disk")

          REMOVABLE="0"
          if [ -f "/sys/block/$DEVNAME/removable" ]; then
            REMOVABLE=$(cat "/sys/block/$DEVNAME/removable")
          fi

          SIZE_BLOCKS=$(cat "/sys/block/$DEVNAME/size" 2>/dev/null || echo 0)
          SIZE_GB=$((SIZE_BLOCKS * 512 / 1073741824))

          echo "  $disk: ''${SIZE_GB}GB, removable=$REMOVABLE"

          if [ "$REMOVABLE" = "1" ]; then
            echo "    Skipping (removable)"
            continue
          fi

          if [ "$SIZE_GB" -lt 50 ]; then
            echo "    Skipping (too small, need >= 50GB)"
            continue
          fi

          # Skip large HDDs — those are likely for ZFS storage pools
          if [ "$SIZE_GB" -gt 1000 ] && [[ "$disk" == /dev/sd* ]]; then
            echo "    Skipping (large HDD, likely ZFS storage)"
            continue
          fi

          TARGET_DISK="$disk"
          echo "    Selected as install target"
          break
        done
        [ -n "$TARGET_DISK" ] && break
      done

      if [ -z "$TARGET_DISK" ]; then
        echo "ERROR: No suitable disk found (need non-removable >= 50GB, <= 1TB)"
        lsblk -d -o NAME,SIZE,TYPE,TRAN,RM
        exit 1
      fi

      # ── Countdown / abort window ────────────────────────────
      echo ""
      echo "  Target disk: $TARGET_DISK — ALL DATA WILL BE ERASED"
      echo "  Press Ctrl+C to abort (10 seconds)."
      echo ""
      for i in $(seq 10 -1 1); do echo -n "$i... "; sleep 1; done
      echo ""

      # ── Partition ───────────────────────────────────────────
      echo ""
      echo "-- Partitioning $TARGET_DISK --"

      umount -R /mnt 2>/dev/null || true
      umount -l "$TARGET_DISK"* 2>/dev/null || true
      swapoff "$TARGET_DISK"* 2>/dev/null || true
      vgchange -an 2>/dev/null || true
      dmsetup remove_all 2>/dev/null || true

      wipefs -af "$TARGET_DISK" 2>/dev/null || true
      dd if=/dev/zero of="$TARGET_DISK" bs=1M count=4 2>/dev/null || true
      sync
      partprobe "$TARGET_DISK" 2>/dev/null || true
      sleep 2

      parted -s "$TARGET_DISK" -- \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart primary 513MiB 100%

      if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
        PART_ESP="''${TARGET_DISK}p1"
        PART_ROOT="''${TARGET_DISK}p2"
      else
        PART_ESP="''${TARGET_DISK}1"
        PART_ROOT="''${TARGET_DISK}2"
      fi

      sleep 2
      partprobe "$TARGET_DISK" 2>/dev/null || true
      sleep 2

      # ── Format ──────────────────────────────────────────────
      mkfs.fat -F 32 -n BOOT "$PART_ESP"
      mkfs.ext4 -F -L nixos "$PART_ROOT"

      # ── Mount ───────────────────────────────────────────────
      mount "$PART_ROOT" /mnt
      mkdir -p /mnt/boot
      mount "$PART_ESP" /mnt/boot

      # ── Fetch NixOS configuration ──────────────────────────
      echo ""
      echo "-- Fetching NixOS configuration --"
      mkdir -p /mnt/etc/nixos

      CONFIG_URL="http://${prov.serverIP}:${toString prov.httpPort}/config/nixos-config.tar.gz"
      if curl -sf "$CONFIG_URL" | tar xz -C /mnt/etc/nixos/; then
        echo "  Configuration fetched"
      else
        echo "ERROR: Failed to fetch config from $CONFIG_URL"
        umount -R /mnt
        exit 1
      fi

      # ── Generate hardware configuration ─────────────────────
      echo ""
      echo "-- Generating hardware configuration --"
      nixos-generate-config --root /mnt

      if [ -d /mnt/etc/nixos/hosts/worker ]; then
        cp -f /mnt/etc/nixos/hardware-configuration.nix \
              /mnt/etc/nixos/hosts/worker/hardware-configuration.nix
      fi

      # ── Set hostname based on MAC or DHCP ───────────────────
      PRIMARY_NIC=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1 || echo "eth0")
      MAC_RAW=$(ip link show "$PRIMARY_NIC" 2>/dev/null | grep ether | awk '{print $2}' || echo "000000")
      MAC_SHORT=$(echo "$MAC_RAW" | tr -d ':' | tail -c 7 | head -c 6)

      DHCP_HOSTNAME=$(hostname 2>/dev/null || echo "")
      if [ -n "$DHCP_HOSTNAME" ] && [ "$DHCP_HOSTNAME" != "localhost" ]; then
        NEW_HOSTNAME="$DHCP_HOSTNAME"
      else
        NEW_HOSTNAME="node-$MAC_SHORT"
      fi

      echo "  Hostname: $NEW_HOSTNAME (MAC: $MAC_RAW)"

      # ── Install NixOS (from local binary cache) ─────────────
      echo ""
      echo "-- Installing NixOS --"
      echo "  Using binary cache at http://${prov.serverIP}:5000"

      mkdir -p /mnt/etc/nix
      cat > /mnt/etc/nix/nix.conf << NIXCONF
      experimental-features = nix-command flakes
      substituters = http://${prov.serverIP}:5000
      require-sigs = false
      NIXCONF

      # Try node-specific config first, fall back to generic worker
      nixos-install \
        --no-root-passwd \
        --no-channel-copy \
        --option substituters "http://${prov.serverIP}:5000" \
        --option require-sigs false \
        2>&1 || {
          echo "ERROR: nixos-install failed"
          exit 1
        }

      # ── Fetch K3s token for cluster join ───────────────────
      echo ""
      echo "-- Fetching K3s cluster token --"
      K3S_TOKEN_URL="http://${prov.serverIP}:${toString prov.httpPort}/config/k3s-token"
      if curl -sf "$K3S_TOKEN_URL" -o /mnt/etc/k3s-token; then
        chmod 600 /mnt/etc/k3s-token
        echo "  K3s token saved"
      else
        echo "  WARNING: Could not fetch K3s token. Node won't auto-join cluster."
      fi

      # ── Clover Setup (older Dell servers only) ──────────────
      if [ "$NEEDS_CLOVER" = "true" ]; then
        echo ""
        echo "-- Setting up Clover NVMe bootloader --"

        CLOVER_DISK=""
        for disk in /dev/sd[a-z]; do
          [ -b "$disk" ] || continue
          DEVNAME=$(basename "$disk")
          SIZE_BLOCKS=$(cat "/sys/block/$DEVNAME/size" 2>/dev/null || echo 0)
          SIZE_GB=$((SIZE_BLOCKS * 512 / 1073741824))

          if [ "$SIZE_GB" -ge 1 ] && [ "$SIZE_GB" -le 64 ] && [ "$disk" != "$TARGET_DISK" ]; then
            CLOVER_DISK="$disk"
            break
          fi
        done

        if [ -z "$CLOVER_DISK" ]; then
          echo "  WARNING: No USB/SD found for Clover. Manual setup needed."
        else
          echo "  Installing Clover to $CLOVER_DISK..."
          wipefs -af "$CLOVER_DISK" 2>/dev/null || true
          parted -s "$CLOVER_DISK" -- mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
          sleep 2

          CLOVER_PART="''${CLOVER_DISK}1"
          mkfs.fat -F 32 -n CLOVER "$CLOVER_PART"

          mkdir -p /tmp/clover-mnt
          mount "$CLOVER_PART" /tmp/clover-mnt

          mkdir -p /tmp/clover-mnt/EFI/CLOVER/drivers/UEFI
          mkdir -p /tmp/clover-mnt/EFI/BOOT

          CLOVER_URL="http://${prov.serverIP}:${toString prov.httpPort}/clover"
          curl -sf "$CLOVER_URL/CLOVERX64.efi" -o /tmp/clover-mnt/EFI/CLOVER/CLOVERX64.efi
          curl -sf "$CLOVER_URL/BOOTX64.efi" -o /tmp/clover-mnt/EFI/BOOT/BOOTX64.efi
          curl -sf "$CLOVER_URL/NvmExpressDxe.efi" -o /tmp/clover-mnt/EFI/CLOVER/drivers/UEFI/NvmExpressDxe.efi

          curl -sf "$CLOVER_URL/config.plist.template" | \
            sed "s/__HOSTNAME__/$NEW_HOSTNAME/g" > /tmp/clover-mnt/EFI/CLOVER/config.plist

          umount /tmp/clover-mnt
          echo "  Clover installed on $CLOVER_DISK"
        fi
      fi

      # ── Register with provisioning server ───────────────────
      IP_ADDR=$(ip -4 addr show "$PRIMARY_NIC" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
      curl -sf "http://${prov.serverIP}:${toString prov.httpPort}/register?hostname=$NEW_HOSTNAME&mac=$MAC_RAW&ip=$IP_ADDR&product=$PRODUCT" \
        2>/dev/null || true

      # ── Done ────────────────────────────────────────────────
      echo ""
      echo "========================================================"
      echo "  Installation Complete!"
      echo "  Hostname: $NEW_HOSTNAME"
      echo "  Disk:     $TARGET_DISK"
      echo "  MAC:      $MAC_RAW"
      echo "  Rebooting in 5 seconds..."
      echo "========================================================"

      mkdir -p /mnt/var/log
      cp "$LOG" /mnt/var/log/first-install.log 2>/dev/null || true

      sync
      umount -R /mnt 2>/dev/null || true
      sleep 5
      systemctl reboot
    '';
  };
}
