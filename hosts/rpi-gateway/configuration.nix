{ config, pkgs, ... }:
let
  nasDiscover = pkgs.writeShellScript "discover-existing-btrfs-nas" ''
    set -eu
    ${pkgs.util-linux}/bin/lsblk --json --bytes --output PATH,SIZE,FSTYPE,UUID,TYPE \
      | ${pkgs.python3}/bin/python3 ${../..}/scripts/discover-nas.py \
          --min-bytes 3500000000000 --link /run/nas-device
  '';
  gatewaySync = pkgs.writeShellScript "k3s-gateway-sync" ''
    exec ${pkgs.python3}/bin/python3 /etc/k3s-gateway-sync.py
  '';
in
{
  imports = [
    ../../modules/common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "rpi-gateway";
  cluster.wireguard.address = "10.100.0.12/24";
  nixpkgs.hostPlatform = "aarch64-linux";
  sdImage.rootVolumeLabel = "nixos-root";
  boot.zfs.forceImportRoot = false;

  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 2049 ];
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wg0" ];
  };
  networking.nftables.tables.cluster-access = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority -10; policy accept;
        ip saddr != 10.7.4.0/24 udp dport 51820 drop
        ip saddr != { 10.7.4.0/24, 10.100.0.0/24 } tcp dport 22 drop
        ip saddr != 10.100.0.0/24 tcp dport 2049 drop
      }
    '';
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernelModules = [ "btrfs" "nf_nat" ];
  boot.supportedFilesystems = [ "btrfs" ];
  networking.nftables.enable = true;

  environment.etc."k3s-gateway-sync.py" = {
    source = ../../scripts/k3s-gateway-sync.py;
    mode = "0555";
  };
  environment.etc."wireguard-peer-sync.py" = {
    source = ../../scripts/wireguard-peer-sync.py;
    mode = "0555";
  };
  environment.systemPackages = with pkgs; [
    btrfs-progs
    iproute2
    kubectl
    nfs-utils
    nftables
    python3
    wireguard-tools
  ];

  systemd.services.discover-nas = {
    description = "Identify the existing 4 TB Btrfs NAS without modifying it";
    wantedBy = [ "local-fs.target" ];
    before = [ "mnt-nas.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${nasDiscover}";
  };
  systemd.mounts = [
    {
      what = "/run/nas-device";
      where = "/mnt/nas";
      type = "btrfs";
      options = "compress=zstd,nofail";
      requires = [ "discover-nas.service" ];
      after = [ "discover-nas.service" ];
    }
    {
      what = "/mnt/nas";
      where = "/srv/nfs4/mnt/nas";
      type = "none";
      options = "bind";
      requires = [ "mnt-nas.mount" ];
      after = [ "mnt-nas.mount" ];
    }
  ];
  systemd.automounts = [{
    where = "/mnt/nas";
    wantedBy = [ "multi-user.target" ];
  }];

  systemd.services.btrfs-nas-scrub = {
    description = "Scrub the existing NAS Btrfs filesystem";
    unitConfig.RequiresMountsFor = [ "/mnt/nas" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.btrfs-progs}/bin/btrfs scrub start -B /mnt/nas";
    };
  };
  systemd.timers.btrfs-nas-scrub = {
    description = "Monthly Btrfs NAS scrub";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
      Unit = "btrfs-nas-scrub.service";
    };
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nfs4 10.100.0.0/24(ro,sync,no_subtree_check,fsid=0,crossmnt)
      /srv/nfs4/mnt/nas 10.100.0.0/24(rw,sync,no_subtree_check,fsid=1,crossmnt,no_root_squash)
    '';
  };
  systemd.tmpfiles.rules = [
    "d /mnt/nas 0755 root root -"
    "d /srv/nfs4 0755 root root -"
    "d /srv/nfs4/mnt 0755 root root -"
  ];
  systemd.services.nfs-server = {
    requires = [ "srv-nfs4-mnt-nas.mount" ];
    after = [ "srv-nfs4-mnt-nas.mount" ];
    unitConfig.RequiresMountsFor = [ "/mnt/nas" ];
  };

  systemd.services.k3s-gateway-sync = {
    description = "Discover Kubernetes services and reconcile nftables forwarding";
    after = [ "network-online.target" "wireguard-wg0.service" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      iproute2
      kubectl
      nftables
      wireguard-tools
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = gatewaySync;
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /run/k3s-gateway-sync/cache";
      User = "root";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/run" ];
    };
  };
  systemd.timers.k3s-gateway-sync = {
    description = "Reconcile Kubernetes exposure every ten seconds";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "10s";
      AccuracySec = "1s";
      Unit = "k3s-gateway-sync.service";
    };
  };

}
