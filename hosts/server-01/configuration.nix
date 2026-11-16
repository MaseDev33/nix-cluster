{ ... }:
{
  imports = [
    ../../modules/compute-node.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "server-01";
  cluster.wireguard.address = "10.100.0.10/24";
  services.k3s.clusterInit = true;
  services.k3s.extraFlags = [
    "--node-name=server-01"
    "--node-ip=10.100.0.10"
    "--advertise-address=10.100.0.10"
    "--tls-san=10.100.0.10"
    "--tls-san=10.100.0.11"
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = true;
}
