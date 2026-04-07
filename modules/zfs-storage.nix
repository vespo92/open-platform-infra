# ZFS Storage Module
#
# Manages ZFS pool scrubbing, trimming, dataset initialization, and health monitoring.
#
# ZFS pool must be created MANUALLY after first boot:
#
#   # Option A: raidz1 (better capacity, 1 disk fault tolerance)
#   zpool create -o ashift=12 tank raidz1 /dev/sda /dev/sdb /dev/sdc /dev/sdd
#
#   # Option B: mirrors (better random I/O, 1 disk per pair)
#   zpool create -o ashift=12 tank mirror /dev/sda /dev/sdb mirror /dev/sdc /dev/sdd
#
# After pool creation:
#   zfs set compression=lz4 tank
#   zfs set atime=off tank
#
# Then add to node-config.nix:
#   enableZfs = true;
#   zfsPools = [ "tank" ];
{ config, pkgs, lib, ... }:

{
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "monthly";
    };
    trim = {
      enable = true;
      interval = "weekly";
    };
  };

  # Initialize standard datasets after pool import
  systemd.services.zfs-dataset-init = {
    description = "Initialize ZFS datasets for cluster services";
    after = [ "zfs-mount.service" ];
    wants = [ "zfs-mount.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.zfs ];
    script = ''
      # Iterate over all pools defined in boot.zfs.extraPools
      for POOL in $(zpool list -H -o name 2>/dev/null); do
        echo "Checking pool: $POOL"

        for ds in staging backups vms; do
          if ! zfs list "$POOL/$ds" &>/dev/null; then
            echo "Creating dataset: $POOL/$ds"
            zfs create "$POOL/$ds"
          fi
        done

        zfs set compression=lz4 "$POOL" 2>/dev/null || true
        zfs set atime=off "$POOL" 2>/dev/null || true
      done

      echo "ZFS datasets ready"
    '';
  };

  # Health monitoring script
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "zfs-health" ''
      echo "=== ZFS Pool Health ==="
      ${pkgs.zfs}/bin/zpool status
      echo ""
      echo "=== ZFS Space Usage ==="
      ${pkgs.zfs}/bin/zfs list -o name,used,avail,refer,compression
      echo ""
      echo "=== Disk Health ==="
      for disk in /dev/sd[a-z]; do
        [ -b "$disk" ] || continue
        echo "--- $disk ---"
        ${pkgs.smartmontools}/bin/smartctl -H "$disk" 2>/dev/null | grep -E 'SMART overall|Temperature|Reallocated|Current Pending' | sed 's/^/  /' || echo "  (no SMART data)"
      done
    '')
  ];
}
