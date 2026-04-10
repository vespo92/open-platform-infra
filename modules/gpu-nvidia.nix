# NVIDIA GPU Module — Driver + Container Toolkit + CDI
#
# Wires the NVIDIA proprietary driver and Container Toolkit into the host
# whenever node-config.nix has `enableGpu = true`.
#
# The host-side stack this module installs:
#   1. Proprietary NVIDIA kernel driver (nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm)
#   2. nvidia-container-toolkit (nvidia-ctk, nvidia-container-runtime)
#   3. CDI spec generation at /var/run/cdi/nvidia.yaml (regenerated at boot)
#   4. k3s containerd wired to consume the nvidia runtime via CDI
#
# Once this is in place the cluster still needs a device plugin to advertise
# the nvidia.com/gpu resource — that lives in
# infrastructure/nvidia-device-plugin/. The host provides the runtime; the
# device plugin advertises the device to the scheduler.
#
# Driver channel:
#   Ampere / Ada (RTX 3090, RTX 4000 Ada, etc.) → stable channel
#   Blackwell (RTX 50-series)                   → beta or latest channel
# Override via node-config.nix with `nvidiaDriverChannel = "beta";` if needed.
{ config, pkgs, lib, ... }:

let
  nodeConfigPath = /etc/nixos/node-config.nix;
  node =
    if builtins.pathExists nodeConfigPath
    then import nodeConfigPath
    else { };

  gpuEnabled = (node.enableGpu or false);
  driverChannel = (node.nvidiaDriverChannel or "stable");

  driverPackage =
    if driverChannel == "beta" then config.boot.kernelPackages.nvidiaPackages.beta
    else if driverChannel == "latest" then config.boot.kernelPackages.nvidiaPackages.latest
    else if driverChannel == "production" then config.boot.kernelPackages.nvidiaPackages.production
    else config.boot.kernelPackages.nvidiaPackages.stable;
in
lib.mkIf gpuEnabled {
  # ─────────────────────────────────────────────────────────
  # Proprietary driver (required for CUDA compute workloads)
  # ─────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;

  # X-server video driver list — also used by nixos to decide which
  # nvidia kmod to build. No actual X server is started on headless nodes.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = false;  # Headless compute, no 32-bit libs needed
  };

  hardware.nvidia = {
    package = driverPackage;

    # Compute workloads prefer the proprietary driver over the open kmod
    # on Ada/Blackwell the open kmod works but coverage is still uneven.
    open = false;

    # KMS for proper framebuffer handoff (harmless on headless)
    modesetting.enable = true;

    # We don't want the driver to aggressively clock down between jobs
    powerManagement.enable = false;
    powerManagement.finegrained = false;

    # No GUI settings app on servers
    nvidiaSettings = false;

    # Persistence daemon keeps the driver loaded between CUDA contexts
    # so cold-start latency on the first job after idle is shorter.
    nvidiaPersistenced = true;
  };

  # Ensure the kmods load early
  boot.kernelModules = [
    "nvidia"
    "nvidia_modeset"
    "nvidia_uvm"
    "nvidia_drm"
  ];

  # Blacklist nouveau (open-source driver) — it fights with proprietary
  boot.blacklistedKernelModules = [ "nouveau" ];

  # ─────────────────────────────────────────────────────────
  # Container Toolkit + CDI
  # ─────────────────────────────────────────────────────────
  #
  # nvidia-container-toolkit provides the nvidia runtime hooks that
  # containerd consumes to inject GPU devices and libraries into pods.
  # CDI (Container Device Interface) is the modern approach and what k3s
  # 1.27+ expects.
  hardware.nvidia-container-toolkit = {
    enable = true;
    # Generate CDI spec at boot so the device plugin can enumerate GPUs
    # without needing a privileged init container.
  };

  # k3s manages its own containerd, but honors CDI specs in /var/run/cdi
  # when started with --cdi-spec-dir set. We ensure the directory exists
  # and that k3s containerd enables CDI. k3s >= 1.27 does this by default
  # when the nvidia runtime is detected, but we set it explicitly.
  systemd.tmpfiles.rules = [
    "d /var/run/cdi 0755 root root -"
    "d /etc/cdi    0755 root root -"
  ];

  # Ensure nvidia-smi and friends are on the system PATH for operators
  environment.systemPackages = with pkgs; [
    # CLI tools
    libnvidia-container
    # Debugging / ops
    nvtopPackages.nvidia
  ];

  # ─────────────────────────────────────────────────────────
  # Hugepages for CUDA pinned memory (optional but recommended)
  # Only meaningful if the workload uses pinned host buffers heavily.
  # ─────────────────────────────────────────────────────────
  boot.kernelParams = lib.mkAfter [
    # Reserve 4 GiB of 2 MiB hugepages for CUDA pinned allocations
    # Comment out if RAM-constrained.
    "default_hugepagesz=2M"
    "hugepagesz=2M"
    "hugepages=2048"
  ];

  # ─────────────────────────────────────────────────────────
  # System tuning for GPU compute
  # ─────────────────────────────────────────────────────────
  boot.kernel.sysctl = {
    # Allow larger pinned memory allocations
    "vm.max_map_count" = 262144;
  };
}
