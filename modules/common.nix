{ config, lib, pkgs, ... }:
let
  cfg = config.cluster;
in
{
  imports = [ ./wireguard.nix ];

  options.cluster = {
    githubOwner = lib.mkOption {
      type = lib.types.str;
      default = "MaseDev33";
      description = "GitHub account or organization owning the public nix-cluster repository.";
    };

    asteriskRepository = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:${cfg.githubOwner}/asterisk-configs-private.git";
      description = "SSH URL for the private Asterisk configuration repository.";
    };
  };

  config = {
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    networking.nftables.enable = true;
    networking.firewall.backend = "nftables";

    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "us";

    users.mutableUsers = true;
    users.users.lyrexo = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      description = "Cluster administrator";
    };
    security.sudo.wheelNeedsPassword = true;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
      };
    };
    environment.systemPackages = with pkgs; [
      btrfs-progs
      curl
      git
      htop
      jq
      openssh
      util-linux
      vim
      wireguard-tools
    ];

    system.autoUpgrade = {
      enable = true;
      flake = "github:${cfg.githubOwner}/nix-cluster#${config.networking.hostName}";
      dates = "*:0/15";
      allowReboot = false;
      flags = [ "--refresh" ];
    };

    system.stateVersion = "26.05";
  };
}
