# Base configuration shared by all nodes
# Provides: users, SSH, packages, firewall defaults, nix settings
{ config, pkgs, lib, ... }:

{
  # ── System ──────────────────────────────────────────────────

  system.stateVersion = "24.11";
  nixpkgs.hostPlatform = "x86_64-linux";

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "admin" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # ── Boot ────────────────────────────────────────────────────

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Serial console for iDRAC/IPMI virtual console
  boot.kernelParams = lib.mkDefault [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  # ── Locale & Time ──────────────────────────────────────────

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Users ───────────────────────────────────────────────────
  # Override SSH keys in your site-specific configuration or node-config.nix

  users.mutableUsers = false;

  users.users.admin = {
    isNormalUser = true;
    description = "Administrator";
    extraGroups = [ "wheel" "networkmanager" ];
    # Set your SSH keys in node-config.nix or site configuration
    openssh.authorizedKeys.keys = [];
  };

  security.sudo.wheelNeedsPassword = false;

  # ── SSH ─────────────────────────────────────────────────────

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = lib.mkDefault false;
      KbdInteractiveAuthentication = false;
    };
    openFirewall = true;
  };

  # ── Core Packages ──────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
    jq
    dig
    tcpdump
    ethtool
    iproute2
    iperf3
    lsof
    pciutils
    usbutils
    smartmontools
    nvme-cli
  ];

  # ── Firewall (defaults - each module opens its own ports) ──

  networking.firewall = {
    enable = true;
    allowPing = true;
    logReversePathDrops = true;
  };

  # ── Journal ─────────────────────────────────────────────────

  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=30day
  '';

  # ── Performance ─────────────────────────────────────────────

  boot.kernel.sysctl = {
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_fastopen" = 3;
  };
}
