# Monitoring module — Prometheus node exporter on every node
{ config, pkgs, lib, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "0.0.0.0";
    enabledCollectors = [
      "systemd"
      "processes"
      "filesystem"
      "diskstats"
      "netdev"
      "meminfo"
      "cpu"
      "loadavg"
      "thermal_zone"
      "zfs"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 9100 ];
}
