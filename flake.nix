{
  description = "Lyrexo three-node NixOS and Kubernetes cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, nixos-hardware, ... }: {
    nixosConfigurations = {
      server-01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/server-01/configuration.nix ];
      };

      server-02 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/server-02/configuration.nix ];
      };

      rpi-gateway = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          (nixpkgs.outPath + "/nixos/modules/installer/sd-card/sd-image-aarch64.nix")
          nixos-hardware.nixosModules.raspberry-pi-4
          ./hosts/rpi-gateway/configuration.nix
        ];
      };
    };

    checks = {
      aarch64-darwin = let
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      in {
        repository-validation = pkgs.runCommand "nix-cluster-validation" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.nix
            pkgs.python3
            pkgs.python3Packages.pyyaml
          ];
        } ''
          cp -R ${self} source
          chmod -R u+w source
          cd source
          export PYTHONDONTWRITEBYTECODE=1
          python3 -m unittest discover -s scripts -p 'test_*.py' -v
          python3 -m py_compile scripts/discover-nas.py scripts/wireguard-peer-sync.py \
            scripts/k3s-gateway-sync.py scripts/test_k3s_gateway_sync.py \
            scripts/test_discover_nas.py
          python3 - <<'PY'
          import yaml
          from pathlib import Path
          for path in Path("k8s").glob("*.yaml"):
              assert all(isinstance(doc, dict) for doc in yaml.safe_load_all(path.read_text()))
          PY
          bash -n scripts/asterisk-git-backup.sh scripts/bootstrap-node.sh \
            scripts/export-gateway-kubeconfig.sh scripts/install-server-01.sh \
            scripts/install-server-02.sh scripts/install-rpi-gateway.sh \
            scripts/provision-ssh-key.sh
          find . -type f -name '*.nix' -exec nix-instantiate --parse {} \;
          touch "$out"
        '';
      };
      x86_64-linux = {
        server-01 = self.nixosConfigurations.server-01.config.system.build.toplevel;
      };
      aarch64-linux = {
        server-02 = self.nixosConfigurations.server-02.config.system.build.toplevel;
        rpi-gateway = self.nixosConfigurations.rpi-gateway.config.system.build.toplevel;
      };
    };
  };
}
