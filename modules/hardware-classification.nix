# Hardware Classification — Runtime hardware fact gathering
#
# Generates /etc/hardware-facts.json at boot with detected hardware
# capabilities. The hardware-discovery DaemonSet reads this file
# and applies corresponding Kubernetes node labels.
#
# Detected facts:
#   - ECC memory (edac module presence + dimm type)
#   - NVMe drives (block device enumeration)
#   - CPU features (model, cores, architecture flags)
#   - Total system RAM
#   - GPU presence (PCI device scan)
{ config, pkgs, lib, ... }:

{
  # Generate hardware facts on every boot
  systemd.services.hardware-facts = {
    description = "Gather hardware facts for Kubernetes node classification";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils gnugrep gawk pciutils util-linux jq dmidecode ];
    script = ''
      # ECC detection: check DMI decode for Error Correcting memory
      ECC="false"
      if command -v dmidecode &>/dev/null; then
        ecc_type=$(dmidecode -t memory 2>/dev/null | grep -i "Error Correcting Type" | head -1 | awk -F: '{print $2}' | xargs)
        if echo "$ecc_type" | grep -qi "single-bit\|multi-bit\|crc"; then
          ECC="true"
        fi
      fi
      # Fallback: check if edac module loaded (kernel detected ECC controller)
      if [ "$ECC" = "false" ] && [ -d /sys/devices/system/edac/mc ]; then
        mc_count=$(find /sys/devices/system/edac/mc -maxdepth 1 -name "mc*" -type d 2>/dev/null | wc -l)
        if [ "$mc_count" -gt 0 ]; then
          ECC="true"
        fi
      fi

      # NVMe detection
      NVME_COUNT=$(lsblk -d -n -o NAME | grep -c "^nvme" || echo "0")
      HAS_NVME="false"
      [ "$NVME_COUNT" -gt 0 ] && HAS_NVME="true"

      # CPU info
      CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | xargs)
      CPU_CORES=$(nproc)
      CPU_ARCH=$(uname -m)

      # Total RAM in GiB
      RAM_GIB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)

      # GPU detection via PCI
      HAS_NVIDIA="false"
      HAS_AMD_GPU="false"
      if lspci 2>/dev/null | grep -qi "NVIDIA.*\(VGA\|3D\|Display\)"; then
        HAS_NVIDIA="true"
      fi
      if lspci 2>/dev/null | grep -qi "AMD.*\(VGA\|Display\).*Radeon"; then
        HAS_AMD_GPU="true"
      fi

      # Storage class heuristic: if NVMe present AND total NVMe capacity > 200GB
      STORAGE_CLASS="hdd"
      if [ "$HAS_NVME" = "true" ]; then
        total_nvme_bytes=0
        for dev in /sys/block/nvme*; do
          if [ -f "$dev/size" ]; then
            sectors=$(cat "$dev/size")
            bytes=$((sectors * 512))
            total_nvme_bytes=$((total_nvme_bytes + bytes))
          fi
        done
        total_nvme_gib=$((total_nvme_bytes / 1073741824))
        if [ "$total_nvme_gib" -gt 200 ]; then
          STORAGE_CLASS="nvme"
        fi
      fi

      # Write facts
      jq -n \
        --arg ecc "$ECC" \
        --arg has_nvme "$HAS_NVME" \
        --argjson nvme_count "$NVME_COUNT" \
        --arg cpu_model "$CPU_MODEL" \
        --argjson cpu_cores "$CPU_CORES" \
        --arg cpu_arch "$CPU_ARCH" \
        --argjson ram_gib "$RAM_GIB" \
        --arg has_nvidia "$HAS_NVIDIA" \
        --arg has_amd_gpu "$HAS_AMD_GPU" \
        --arg storage_class "$STORAGE_CLASS" \
        '{
          ecc: ($ecc == "true"),
          nvme: { present: ($has_nvme == "true"), count: $nvme_count },
          cpu: { model: $cpu_model, cores: $cpu_cores, arch: $cpu_arch },
          ram_gib: $ram_gib,
          gpu: { nvidia: ($has_nvidia == "true"), amd: ($has_amd_gpu == "true") },
          storage_class: $storage_class,
          collected_at: now | todate
        }' > /etc/hardware-facts.json

      chmod 644 /etc/hardware-facts.json
      echo "Hardware facts written to /etc/hardware-facts.json"
    '';
  };

  # Load edac modules early so ECC detection works
  boot.kernelModules = [ "edac_core" ];
}
