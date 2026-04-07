# Kea DHCP Server for Provisioning VLAN
#
# The provisioning VLAN is a FLAT L2 segment — no gateway, no internet.
# The first node serves DHCP + TFTP + HTTP + nix binary cache.
# PXE clients boot and install entirely from the local network.
#
# PXE boot chain:
#   1. Bare PXE ROM → DHCP here → TFTP → iPXE firmware (ipxe.efi or undionly.kpxe)
#   2. iPXE firmware → DHCP again → HTTP → boot.ipxe script
#   3. boot.ipxe → HTTP → kernel + initrd → NixOS boots in RAM
#   4. Auto-installer → nix-serve binary cache → install to disk → reboot
{ config, pkgs, lib, ... }:

let
  # Provisioning network constants — customize for your environment
  serverIP = "10.0.64.10";         # Customize: PXE server IP
  subnet = "10.0.64.0/20";        # Customize: provisioning subnet
  rangeStart = "10.0.64.100";     # Customize: DHCP pool start
  rangeEnd = "10.0.64.200";       # Customize: DHCP pool end
  httpPort = 9080;
  vlanId = 105;                    # Customize: provisioning VLAN ID
  parentInterface = "eno1";        # Customize: NIC that carries the VLAN tag
  vlanInterface = "${parentInterface}.${toString vlanId}";
in
{
  # VLAN sub-interface for provisioning
  systemd.network.netdevs."25-provision" = {
    netdevConfig = {
      Name = vlanInterface;
      Kind = "vlan";
    };
    vlanConfig.Id = vlanId;
  };

  # Attach VLAN to parent NIC
  systemd.network.networks."10-primary".vlan = [ vlanInterface ];

  systemd.network.networks."25-provision" = {
    matchConfig.Name = vlanInterface;
    networkConfig.DHCP = "no";
    address = [ "${serverIP}/20" ];
    # NO routes — flat L2, isolated by design
  };

  # Kea DHCP4 Server
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      valid-lifetime = 600;
      max-valid-lifetime = 1800;
      renew-timer = 300;
      rebind-timer = 450;

      interfaces-config = {
        interfaces = [ vlanInterface ];
      };

      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };

      # PXE client classes — standard iPXE chainload
      client-classes = [
        # Stage 2: iPXE requesting boot script via HTTP
        {
          name = "ipxe";
          test = "substring(option[77].hex,0,4) == 0x69505845";
          boot-file-name = "http://${serverIP}:${toString httpPort}/boot.ipxe";
        }
        # Stage 1a: UEFI PXE ROM → TFTP iPXE EFI binary
        {
          name = "uefi-pxe";
          test = "not member('ipxe') and option[93].hex == 0x0007";
          next-server = serverIP;
          boot-file-name = "ipxe.efi";
        }
        # Stage 1a (alt): EFI HTTP Boot
        {
          name = "uefi-http";
          test = "not member('ipxe') and option[93].hex == 0x0010";
          boot-file-name = "http://${serverIP}:${toString httpPort}/ipxe.efi";
        }
        # Stage 1b: BIOS/Legacy PXE ROM
        {
          name = "bios-pxe";
          test = "not member('ipxe') and option[93].hex == 0x0000";
          next-server = serverIP;
          boot-file-name = "undionly.kpxe";
        }
      ];

      subnet4 = [
        {
          id = vlanId;
          subnet = subnet;
          next-server = serverIP;
          boot-file-name = "ipxe.efi";

          pools = [
            { pool = "${rangeStart} - ${rangeEnd}"; }
          ];

          option-data = [
            { name = "domain-name-servers"; data = serverIP; }
            { name = "domain-name"; data = "pxe.local"; }
          ];

          # Add MAC reservations for your nodes here:
          # reservations = [
          #   {
          #     hw-address = "aa:bb:cc:dd:ee:ff";
          #     ip-address = "10.0.64.11";
          #     hostname = "node-2";
          #   }
          # ];
          reservations = [];
        }
      ];

      loggers = [
        {
          name = "kea-dhcp4";
          severity = "INFO";
          output-options = [
            { output = "/var/log/kea/kea-dhcp4.log"; maxsize = 10485760; maxver = 3; }
          ];
        }
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kea 0755 root root -"
    "d /var/log/kea 0755 root root -"
  ];

  networking.firewall.allowedUDPPorts = [ 67 68 ];
}
