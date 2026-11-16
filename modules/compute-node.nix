{ config, pkgs, ... }:
let
  backupUnits = pkgs.runCommand "asterisk-git-backup-units" { } ''
    mkdir -p "$out/lib/systemd/system"
    cp ${../systemd/asterisk-git-backup.service} "$out/lib/systemd/system/asterisk-git-backup.service"
    cp ${../systemd/asterisk-git-backup.path} "$out/lib/systemd/system/asterisk-git-backup.path"
    cp ${../systemd/asterisk-git-backup.timer} "$out/lib/systemd/system/asterisk-git-backup.timer"
  '';
in
{
  imports = [ ./common.nix ];

  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
    trustedInterfaces = [ "wg0" ];
  };

  boot.kernelModules = [ "br_netfilter" "overlay" "iscsi_tcp" ];
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };

  services.openiscsi = {
    enable = true;
    name = "iqn.2026-11.local.lyrexo:${config.networking.hostName}";
  };
  environment.systemPackages = with pkgs; [ nfs-utils openiscsi k3s kubectl ];
  systemd.tmpfiles.rules = [
    "d /usr/local/bin 0755 root root -"
    "L+ /usr/local/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  fileSystems."/mnt/nas" = {
    device = "10.100.0.12:/mnt/nas";
    fsType = "nfs4";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "vers=4.2"
      "proto=tcp"
      "timeo=50"
      "retrans=2"
    ];
  };

  environment.etc."asterisk-git-backup.sh" = {
    source = pkgs.replaceVars ../scripts/asterisk-git-backup.sh {
      repository = config.cluster.asteriskRepository;
    };
    mode = "0555";
  };
  systemd.packages = [ backupUnits ];
  systemd.services.asterisk-git-backup.path = with pkgs; [
    git
    openssh
    util-linux
  ];
  systemd.targets.multi-user.wants = [
    "asterisk-git-backup.path"
    "asterisk-git-backup.timer"
  ];

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = "/etc/k3s-token";
    extraFlags = [
      "--disable=traefik"
      "--disable=servicelb"
      "--flannel-iface=wg0"
      "--cluster-cidr=10.42.0.0/16"
      "--service-cidr=10.43.0.0/16"
      "--cluster-dns=10.43.0.10"
      "--kube-controller-manager-arg=node-monitor-period=5s"
      "--kube-controller-manager-arg=node-monitor-grace-period=15s"
      "--kubelet-arg=node-status-update-frequency=5s"
      "--write-kubeconfig-mode=0600"
    ];
  };

}
