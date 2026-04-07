# PXE Boot Server + nix-serve Binary Cache
#
# Provides everything a PXE-booting node needs to install NixOS:
#   TFTP (port 69):   iPXE firmware (ipxe.efi, undionly.kpxe)
#   HTTP (port 9080): kernel, initrd, boot.ipxe, config tarball, Clover files
#   nix-serve (5000): local binary cache serving the provisioning server's /nix/store
#
# Key insight: nix-serve means the provisioning VLAN needs ZERO internet access.
# The first node pre-builds the worker config (has internet), then nix-serve
# exposes the built closures on the provisioning VLAN. Install at wire speed.
{ config, pkgs, lib, ... }:

let
  serverIP = "10.0.64.10";    # Customize: your PXE server IP
  httpPort = 9080;
  nixServePort = 5000;
  pxeRoot = "/srv/pxe";
  httpRoot = "${pxeRoot}/http";
  tftpRoot = "${pxeRoot}/tftp";
  nixosDir = "${httpRoot}/nixos";
  configDir = "${httpRoot}/config";
  cloverDir = "${httpRoot}/clover";
  flakeDir = "/etc/nixos";
in
{
  # TFTP Server (iPXE firmware for bare PXE ROMs)
  services.atftpd = {
    enable = true;
    root = tftpRoot;
  };

  # nix-serve Binary Cache — serves /nix/store as a substituter
  services.nix-serve = {
    enable = true;
    port = nixServePort;
    bindAddress = "0.0.0.0";
  };

  # HTTP Server (nginx)
  services.nginx = {
    enable = true;
    virtualHosts."pxe-provision" = {
      listen = [ { addr = "0.0.0.0"; port = httpPort; } ];
      root = httpRoot;

      locations."/" = {
        extraConfig = ''
          autoindex on;
          sendfile on;
          tcp_nopush on;
        '';
      };
      locations."/register" = {
        extraConfig = ''
          access_log /var/log/nginx/pxe-registrations.log;
          return 200 "registered\n";
        '';
      };
      locations."/config/" = {
        extraConfig = "autoindex on; sendfile on;";
      };
      locations."/clover/" = {
        extraConfig = "autoindex on; sendfile on;";
      };
    };
  };

  # Directory structure
  systemd.tmpfiles.rules = [
    "d ${pxeRoot} 0755 root root -"
    "d ${tftpRoot} 0755 root root -"
    "d ${httpRoot} 0755 root root -"
    "d ${nixosDir} 0755 root root -"
    "d ${configDir} 0755 root root -"
    "d ${cloverDir} 0755 root root -"
    "d /var/log/nginx 0755 root root -"
  ];

  # Deploy iPXE firmware to TFTP
  systemd.services.pxe-firmware-setup = {
    description = "Deploy iPXE firmware to TFTP server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.coreutils ];
    script = ''
      echo "Deploying iPXE firmware..."
      for bin in ipxe.efi undionly.kpxe; do
        for path in "${pkgs.ipxe}/$bin" "${pkgs.ipxe}/share/ipxe/$bin"; do
          if [ -f "$path" ]; then
            cp -f "$path" "${tftpRoot}/$bin"
            echo "  TFTP: $bin"
            break
          fi
        done
      done
      cp -f "${tftpRoot}/"*.efi "${httpRoot}/" 2>/dev/null || true
      cp -f "${tftpRoot}/"*.kpxe "${httpRoot}/" 2>/dev/null || true
    '';
  };

  # Deploy Clover files (for older Dell servers that can't boot NVMe natively)
  systemd.services.pxe-clover-setup = {
    description = "Deploy Clover bootloader files";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.coreutils ];
    script = ''
      CLOVER_SRC="/etc/nixos/clover-prep/CloverV2/CloverV2/EFI"
      DRIVER_SRC="/etc/nixos/clover-prep/CloverV2/CloverV2/EFI/CLOVER/drivers/off/UEFI/Other"

      if [ ! -d "$CLOVER_SRC" ]; then
        echo "Clover source not found — skipping (only needed for older Dell servers)"
        exit 0
      fi

      echo "Deploying Clover files..."
      cp -f "$CLOVER_SRC/CLOVER/CLOVERX64.efi" "${cloverDir}/"
      cp -f "$CLOVER_SRC/BOOT/BOOTX64.efi" "${cloverDir}/" 2>/dev/null || \
        cp -f "$CLOVER_SRC/CLOVER/CLOVERX64.efi" "${cloverDir}/BOOTX64.efi"
      cp -f "$DRIVER_SRC/NvmExpressDxe.efi" "${cloverDir}/"

      cat > "${cloverDir}/config.plist.template" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key><integer>3</integer>
        <key>DefaultVolume</key><string>BOOT</string>
        <key>DefaultLoader</key><string>\EFI\systemd\systemd-bootx64.efi</string>
        <key>Fast</key><true/>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Custom</key>
        <dict>
            <key>Entries</key>
            <array>
                <dict>
                    <key>Volume</key><string>BOOT</string>
                    <key>Loader</key><string>\EFI\systemd\systemd-bootx64.efi</string>
                    <key>Title</key><string>NixOS __HOSTNAME__</string>
                    <key>Type</key><string>Linux</string>
                </dict>
            </array>
        </dict>
    </dict>
</dict>
</plist>
PLIST
    '';
  };

  # Config tarball generation
  systemd.services.pxe-config-tarball = {
    description = "Generate NixOS config tarball for auto-installer";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.coreutils pkgs.gnutar pkgs.gzip ];
    script = ''
      if [ -d "${flakeDir}" ] && [ -f "${flakeDir}/flake.nix" ]; then
        echo "Generating config tarball..."
        cd "${flakeDir}"
        tar czf "${configDir}/nixos-config.tar.gz" \
          --exclude='.git' --exclude='result' --exclude='*.swp' \
          --exclude='clover-prep/CloverV2' .
        ls -lh "${configDir}/nixos-config.tar.gz"
      else
        echo "No flake at ${flakeDir} — tarball not generated"
      fi
    '';
  };

  # Admin tools
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-netboot" ''
      set -euo pipefail

      FLAKE="${flakeDir}"
      HTTP="${httpRoot}"

      if [ ! -f "$FLAKE/flake.nix" ]; then
        echo "ERROR: No flake.nix at $FLAKE"
        exit 1
      fi

      echo "========================================"
      echo "  PXE — Build + Cache Netboot"
      echo "========================================"

      echo "[1/4] Building netboot kernel..."
      nix build "$FLAKE#netboot-kernel" -o /tmp/nb-kernel
      KERNEL_BIN=$(find /tmp/nb-kernel -name 'bzImage' -o -name 'Image' | head -1)

      echo "[2/4] Building netboot initrd..."
      nix build "$FLAKE#netboot-initrd" -o /tmp/nb-initrd
      INITRD_BIN=$(find /tmp/nb-initrd -name 'initrd' -o -name 'initrd.zst' | head -1)

      echo "[3/4] Pre-building worker config (populates nix-serve cache)..."
      nix build "$FLAKE#nixosConfigurations.netboot.config.system.build.toplevel" \
        -o /tmp/worker-system 2>&1 || echo "WARNING: Pre-build failed, installer will use cache.nixos.org"

      echo "[4/4] Deploying boot artifacts..."
      cp -fL "$KERNEL_BIN" "$HTTP/nixos/bzImage"
      cp -fL "$INITRD_BIN" "$HTTP/nixos/initrd"

      # Generate boot.ipxe
      cat > "$HTTP/boot.ipxe" << 'IPXE'
#!ipxe

echo ========================================
echo  Open Platform Infra - NixOS PXE Boot
echo ========================================

set boot-url http://${serverIP}:${toString httpPort}

:menu
menu Node Provisioning
item --key a auto       Auto-Install NixOS to disk (DEFAULT)
item --key n netboot    Boot NixOS in RAM (no install)
item --key s shell      iPXE Shell
item --key r reboot     Reboot
choose --timeout 15000 --default auto selected
goto ''${selected}

:auto
kernel ''${boot-url}/nixos/bzImage init=/nix/store/*/init
initrd ''${boot-url}/nixos/initrd
boot

:netboot
kernel ''${boot-url}/nixos/bzImage init=/nix/store/*/init
initrd ''${boot-url}/nixos/initrd
boot

:shell
shell
goto menu

:reboot
reboot
IPXE

      cd "$FLAKE"
      tar czf "${configDir}/nixos-config.tar.gz" \
        --exclude='.git' --exclude='result' --exclude='*.swp' \
        --exclude='clover-prep/CloverV2' .

      echo ""
      echo "Netboot ready."
      echo "  PXE URL: http://${serverIP}:${toString httpPort}/boot.ipxe"
      echo "  Cache:   http://${serverIP}:${toString nixServePort}"
    '')

    (pkgs.writeShellScriptBin "pxe-status" ''
      echo "=== PXE Provisioning Status ==="
      echo ""
      echo "Services:"
      for svc in kea-dhcp4-server atftpd nginx nix-serve; do
        status=$(systemctl is-active $svc 2>/dev/null || echo "not found")
        printf "  %-25s %s\n" "$svc" "$status"
      done
      echo ""
      echo "TFTP:"
      ls -la ${tftpRoot}/ 2>/dev/null | grep -v '^total' | sed 's/^/  /' || echo "  (empty)"
      echo ""
      echo "Netboot images:"
      ls -lh ${nixosDir}/ 2>/dev/null | grep -v '^total' | sed 's/^/  /' || echo "  (none — run update-netboot)"
      echo ""
      echo "nix-serve:"
      curl -sf http://localhost:${toString nixServePort}/nix-cache-info 2>/dev/null && \
        echo "  Cache responding" || echo "  NOT RESPONDING"
      echo ""
      echo "PXE URL: http://${serverIP}:${toString httpPort}/boot.ipxe"
    '')
  ];

  networking.firewall.allowedTCPPorts = [ httpPort nixServePort ];
  networking.firewall.allowedUDPPorts = [ 69 ];
}
