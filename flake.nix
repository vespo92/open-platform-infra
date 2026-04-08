{
  description = "Open Platform Infrastructure — Bare Metal to Cluster";

  # ═══════════════════════════════════════════════════════════
  # Inputs — pinned dependencies for reproducible builds
  # ═══════════════════════════════════════════════════════════
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # ═══════════════════════════════════════════════════════════
  # Deployment Model
  # ═══════════════════════════════════════════════════════════
  #
  # All nodes use `nixos-rebuild switch --no-flake` on the node itself.
  # The flake pins nixpkgs and provides the PXE netboot image.
  # It does NOT replace the on-node deployment workflow.
  #
  # WHY:
  #   1. Workers read /etc/nixos/node-config.nix at eval time —
  #      this file is node-specific and deployed by PXE or manually
  #   2. The flat configuration.nix + node-config.nix pattern is
  #      battle-tested and doesn't need flake indirection
  #
  # THE FLAKE IS FOR:
  #   - Pinning nixpkgs versions (reproducibility)
  #   - Building PXE netboot artifacts (kernel + initrd)
  #   - Dev shell with useful tools

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs-unstable { inherit system; };
    in
    {
      # ── PXE Netboot Installer ─────────────────────────────────
      # Boots in RAM, auto-installs NixOS to disk, reboots into k0s node.
      #
      # Build: nix build .#netboot-kernel .#netboot-initrd
      # Deploy to PXE server:
      #   cp result/bzImage /srv/pxe/tftp/
      #   cp result/initrd /srv/pxe/tftp/
      nixosConfigurations.netboot = nixpkgs-unstable.lib.nixosSystem {
        inherit system;
        modules = [
          ({ modulesPath, lib, pkgs, ... }: {
            imports = [
              "${modulesPath}/installer/netboot/netboot-minimal.nix"
            ];

            system.stateVersion = "24.11";
            nixpkgs.hostPlatform = "x86_64-linux";
            boot.loader.systemd-boot.enable = lib.mkForce false;
            boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
            networking.hostName = lib.mkForce "op-installer";
            networking.hostId = lib.mkForce "00000000";

            users.users.root.hashedPassword = lib.mkForce "";
            users.mutableUsers = lib.mkForce true;
            services.openssh = {
              enable = true;
              settings.PermitRootLogin = lib.mkForce "yes";
              settings.PasswordAuthentication = lib.mkForce true;
            };

            boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
            boot.initrd.availableKernelModules = [
              "xhci_pci" "ahci" "nvme" "sd_mod" "sr_mod"
              "usb_storage" "uas" "megaraid_sas"
              "tg3" "bnx2x" "igb" "ixgbe" "e1000e" "i40e"
            ];

            networking.useDHCP = true;
            networking.firewall.enable = false;

            environment.systemPackages = with pkgs; [
              nixos-install-tools parted dosfstools e2fsprogs
              gnutar gzip curl util-linux pciutils usbutils
              nvme-cli smartmontools jq vim git iproute2
            ];

            nix.settings.experimental-features = [ "nix-command" "flakes" ];
          })

          ./modules/provisioning/auto-installer.nix
        ];
      };

      # ── PXE Build Artifacts ───────────────────────────────────
      packages.${system} = {
        netboot-kernel = self.nixosConfigurations.netboot.config.system.build.kernel;
        netboot-initrd = self.nixosConfigurations.netboot.config.system.build.netbootRamdisk;
      };

      # ── Dev Shell ─────────────────────────────────────────────
      # nix develop — get a shell with deployment tools
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nixos-rebuild
          k0s
          k0sctl
          kubectl
          k9s
          helm
          jq
          fluxcd
        ];
      };
    };
}
