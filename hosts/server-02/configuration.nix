{ ... }:
{
  imports = [
    ../../modules/compute-node.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "server-02";
  cluster.wireguard.address = "10.100.0.11/24";
  services.k3s.serverAddr = "https://10.100.0.10:6443";
  services.k3s.extraFlags = [
    "--node-name=server-02"
    "--node-ip=10.100.0.11"
    "--advertise-address=10.100.0.11"
    "--tls-san=10.100.0.11"
  ];
  nixpkgs.hostPlatform = "aarch64-linux";
}
