{ config, lib, pkgs, ... }:
let
  isGateway = config.networking.hostName == "rpi-gateway";
  address = config.cluster.wireguard.address;
  endpointHost = config.cluster.wireguard.endpointHost;
  peerSync = pkgs.writeShellScript "wireguard-peer-sync" ''
    set -eu
    exec ${pkgs.python3}/bin/python3 ${../scripts/wireguard-peer-sync.py} \
      --role ${if isGateway then "gateway" else "compute"} \
      --hostname ${config.networking.hostName} \
      --endpoint-host ${endpointHost}
  '';
in
{
  options.cluster.wireguard = {
    address = lib.mkOption {
      type = lib.types.str;
      description = "WireGuard address and prefix assigned to this cluster node.";
    };
    endpointHost = lib.mkOption {
      type = lib.types.str;
      default = "rpi-gateway.home.arpa";
      description = "DHCP-aware DNS name for the gateway's reachable WireGuard endpoint.";
    };
  };

  config = {
    networking.wireguard.interfaces.wg0 = {
      ips = [ address ];
      privateKeyFile = "/etc/wireguard/private.key";
      peers = [ ];
    } // lib.optionalAttrs isGateway {
      listenPort = 51820;
    };

    networking.firewall.allowedUDPPorts = [ ];
    networking.firewall.trustedInterfaces = [ "wg0" ];

    systemd.services.wireguard-peer-sync = {
      description = "Reconcile WireGuard peers and refresh the DHCP/DNS endpoint";
      after = [ "network-online.target" "wireguard-wg0.service" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.wireguard-tools ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = peerSync;
      };
    };
    systemd.timers.wireguard-peer-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "30s";
        AccuracySec = "2s";
      };
    };

    networking.firewall.enable = true;
    networking.useDHCP = true;
  };
}
