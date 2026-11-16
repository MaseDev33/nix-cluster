# Lyrexo NixOS cluster

This flake configures three NixOS machines:

| Host | Hardware and OS | Role |
|---|---|---|
| `server-01` | Intel N100, x86_64 bare metal | Initial K3s server; primary workloads; Longhorn replica |
| `server-02` | Apple M4 Mac mini running an aarch64 NixOS guest in bridged UTM | Second K3s server; workloads/failover; Longhorn replica |
| `rpi-gateway` | Raspberry Pi 4, booting NixOS from USB SSD | WireGuard hub, Btrfs NAS/NFS, automatic K3s service gateway, Longhorn backup target |

The Pi is not a K3s node. The Mac mini host remains macOS; only its UTM guest runs NixOS.

## Important limits

* Reserve DHCP addresses on the router in `10.7.4.0/24` and provide local DNS for `server-01.home.arpa`, `server-02.home.arpa`, and `rpi-gateway.home.arpa`. Router address is `10.7.4.1`. The Pi DNS name must resolve locally without Internet.
* WireGuard uses `10.100.0.10` (server-01), `.11` (server-02), and `.12` (Pi), UDP 51820. It uses peer `/32` routes; Internet traffic does not pass through the VPN.
* Two embedded-etcd voters do not provide quorum if either compute node is unavailable. The Pi is not an etcd voter.
* The router must separately forward any desired public inbound traffic to the Pi. This repository does not configure the router.
* Longhorn's two replicas run on compute nodes. The Pi NAS is a backup destination, not a live Longhorn replica.

## Prepare the repository and Nix

Use any Linux or macOS computer with Git and Nix to prepare and publish the flake. The Mac mini is needed only if you choose UTM as the aarch64 Linux build guest. Use `/etc/nixos/nix-cluster` as the checkout path on NixOS nodes and build guests.

Homebrew has no `nix` formula. Install Nix on macOS or Linux using the official terminal installer (it requires administrator approval):

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix -o /tmp/install-determinate-nix.sh
sh /tmp/install-determinate-nix.sh install --determinate --no-confirm
```

Open a new terminal after installation and check:

```sh
nix --version
```

Unpack the delivered `nix-cluster.zip` into `~/nix-cluster`, then create and commit the lockfile:

```sh
mkdir -p ~/nix-cluster
unzip -q ~/Downloads/nix-cluster.zip -d ~/nix-cluster
cd ~/nix-cluster
nix flake lock
nix flake check
```

Create the public GitHub repository `MaseDev33/nix-cluster`, then publish the checkout:

```sh
cd ~/nix-cluster
git init -b main
git add .
git commit -m "Initial NixOS cluster configuration"
git remote add origin https://github.com/MaseDev33/nix-cluster.git
git push -u origin main
```

Do not install nodes until the public repository contains `flake.lock` and `nix flake check` succeeds. Flake evaluation/checks run on any supported Nix host. Full NixOS system builds require a Linux builder matching each target architecture: x86_64-linux for server-01, aarch64-linux for server-02 and the Pi. Build the Pi SD image on an aarch64-linux host such as the UTM guest. If your preparation machine cannot build a target, use its matching Linux installer to build/install that host, or configure a matching remote builder.

On an aarch64-linux host, clone the published flake and evaluate:

```sh
sudo mkdir -p /etc/nixos
sudo git clone https://github.com/MaseDev33/nix-cluster.git /etc/nixos/nix-cluster
cd /etc/nixos/nix-cluster
nix flake check
nix eval --raw .#nixosConfigurations.server-01.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.server-02.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.rpi-gateway.config.system.build.sdImage.drvPath
```

Build the Pi image there with `nix build .#nixosConfigurations.rpi-gateway.config.system.build.sdImage`. Build the server-01 system on an x86_64-linux builder; build server-02 on an aarch64-linux builder. Alternatively, `nixos-install --flake ...` builds the target system from its own matching NixOS installer. Physical hardware behavior still requires actual hardware testing.

## SSH administrator key

On your admin computer, create a key and keep its private half there:

```sh
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/lyrexo_cluster -C lyrexo-cluster-admin
```

For the N100 and UTM guest, use the local console after installation and put the one-line contents of `~/.ssh/lyrexo_cluster.pub` into `/tmp/lyrexo_cluster.pub`. The Pi image builder injects that public key into the Pi image. Never put private keys, the K3s token, or generated kubeconfigs in Git.

## Install the nodes

### server-01: N100 bare metal

1. Boot a NixOS installer in UEFI mode. On the N100's internal SSD only, create an EFI FAT32 partition labelled `EFI` and an ext4 root partition labelled `nixos-root`. Mount them at `/mnt/boot` and `/mnt`.
2. Clone the already-published flake into the new root and install:

```sh
mkdir -p /mnt/etc/nixos
git clone https://github.com/MaseDev33/nix-cluster.git /mnt/etc/nixos/nix-cluster
cd /mnt/etc/nixos/nix-cluster
bash scripts/install-server-01.sh
```

3. Set the root password when prompted, reboot, and log in at the local console. Create `/tmp/lyrexo_cluster.pub`, then bootstrap and activate:

```sh
bash /etc/nixos/nix-cluster/scripts/bootstrap-node.sh server-01 /tmp/lyrexo_cluster.pub
nixos-rebuild switch --flake /etc/nixos/nix-cluster#server-01
```

The installer script does not partition or format disks.

### server-02: M4 Mac mini UTM guest

1. In UTM on macOS, create an aarch64 Linux VM with 16 GB RAM, UEFI, a virtual disk, and bridged networking to the home LAN. Assign its DHCP reservation and local DNS name `server-02.home.arpa`. Do not install NixOS on macOS.
2. Boot the aarch64 NixOS installer in the VM. Partition only its virtual disk (EFI FAT32 label `EFI`, ext4 root label `nixos-root`); mount at `/mnt/boot` and `/mnt`.
3. Clone the flake into the guest root and install:

```sh
mkdir -p /mnt/etc/nixos
git clone https://github.com/MaseDev33/nix-cluster.git /mnt/etc/nixos/nix-cluster
cd /mnt/etc/nixos/nix-cluster
bash scripts/install-server-02.sh
```

4. Set the root password, reboot, create `/tmp/lyrexo_cluster.pub` at the guest console, and bootstrap:

```sh
bash /etc/nixos/nix-cluster/scripts/bootstrap-node.sh server-02 /tmp/lyrexo_cluster.pub
```

When prompted, enter the token created on server-01 (see K3s setup below). Activate server-02 after WireGuard is configured:

```sh
nixos-rebuild switch --flake /etc/nixos/nix-cluster#server-02
```

### rpi-gateway: Raspberry Pi 4 and existing NAS

1. Keep the existing NAS separate. On the aarch64-linux build host, build an SD image and inject only the administrator public key:

```sh
cd /etc/nixos/nix-cluster
sudo bash scripts/install-rpi-gateway.sh /tmp/lyrexo_cluster.pub /tmp/rpi-gateway.img
```

2. Copy `/tmp/rpi-gateway.img` to the machine used to flash media if needed. Flash it to the USB 3 boot SSD with Raspberry Pi Imager or Etcher. Select the boot SSD—not the existing NAS. The script does not flash physical disks.
3. Boot the Pi from USB, set its DHCP reservation and local DNS name to `rpi-gateway.home.arpa`, then SSH in from the admin computer:

```sh
ssh -i ~/.ssh/lyrexo_cluster lyrexo@rpi-gateway.home.arpa
sudo mkdir -p /etc/nixos
sudo git clone https://github.com/MaseDev33/nix-cluster.git /etc/nixos/nix-cluster
sudo bash /etc/nixos/nix-cluster/scripts/bootstrap-node.sh rpi-gateway /home/lyrexo/.ssh/authorized_keys
sudo nixos-rebuild switch --flake /etc/nixos/nix-cluster#rpi-gateway
```

The Pi selects exactly one existing Btrfs filesystem of at least 3.5 TB and mounts it at `/mnt/nas`; discovery fails closed if the match is ambiguous. It never formats or repartitions the NAS. The mount uses `compress=zstd,nofail`, with a monthly scrub. NFSv4 exports only to `10.100.0.0/24`.

## WireGuard, K3s, and storage

Bootstrap creates `/etc/wireguard/private.key`, prints that node's public key, and creates the K3s token on server-01. Exchange only the printed public keys. Store on the Pi:

* Pi `/etc/wireguard/peers/server-01.pub`: server-01 public key
* Pi `/etc/wireguard/peers/server-02.pub`: server-02 public key

Store the Pi public key in `/etc/wireguard/peers/gateway.pub` on both compute nodes. On each host, make the parent directory mode `0700`, key files mode `0644`, then run:

```sh
sudo systemctl start wireguard-peer-sync.service
sudo wg show wg0
```

Securely provide server-01's `/etc/k3s-token` to server-02 at its bootstrap prompt. Once the Pi and both compute peers have handshakes:

```sh
# On server-01:
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes -o wide
```

K3s is configured with Traefik and ServiceLB disabled, Flannel on `wg0`, and the requested 5/15/5-second node monitoring. Both compute nodes are K3s servers. Two-node etcd still requires both nodes for quorum.

On both compute nodes, verify the NFS automount at `/mnt/nas`, open-iscsi, NFS utilities, and `/usr/local/bin/iscsiadm`. Install a Longhorn chart version explicitly compatible with the Kubernetes version in the lockfile; then on server-01 apply:

```sh
sudo mkdir -p /mnt/nas/longhorn-backups /mnt/nas/backups/asterisk
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f /etc/nixos/nix-cluster/k8s/longhorn-rwx.yaml
```

The manifest defines retained `longhorn-rwx`, two replicas, and nightly backups to the Pi NFS share. Do not install example workload applications from this repository; it contains none.

## Automatic Service exposure

Apply the read-only gateway RBAC on server-01:

```sh
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f /etc/nixos/nix-cluster/k8s/gateway-rbac.yaml
```

After the `gateway-sync-token` Secret is populated, export `/etc/rancher/k3s/gateway.yaml` using `scripts/export-gateway-kubeconfig.sh` and a temporary administrator kubeconfig. Store the generated file only on the Pi, root-owned mode `0600`.

The Pi timer runs `k3s-gateway-sync` every 10 seconds. It queries server-01 then server-02, discovers `LoadBalancer` and `NodePort` Services, handles TCP/UDP and healthy endpoints, prefers server-01, and atomically reconciles its nftables rules. Deleted Services lose their rules; API outages preserve current rules. No NixOS port-list edit is needed for new Services.

Run mocked tests from the checkout:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

## Asterisk backup and operations

The compute nodes include path and timer units for `/mnt/nas/backups/asterisk`. Create that directory on the Pi. On both compute nodes provision `/etc/ssh/asterisk_backup_key` (mode `0600`) and a verified GitHub key in `/etc/ssh/ssh_known_hosts`. Create the private repository `MaseDev33/asterisk-configs-private`, authorize the backup key, and initialize the NAS checkout with origin `git@github.com:MaseDev33/asterisk-configs-private.git`. Then enable:

```sh
sudo systemctl enable --now asterisk-git-backup.path asterisk-git-backup.timer
```

To update, commit and push changes to the public flake, including `flake.lock`, then update one host at a time:

```sh
sudo nixos-rebuild switch --flake /etc/nixos/nix-cluster#server-01
sudo nixos-rebuild switch --flake /etc/nixos/nix-cluster#server-02
sudo nixos-rebuild switch --flake /etc/nixos/nix-cluster#rpi-gateway
```

For recovery, inspect `journalctl -u k3s`, `wg show`, `journalctl -u k3s-gateway-sync`, `nft list table inet k3s_gateway`, `journalctl -u discover-nas`, and the previous NixOS generation. Never reinitialize etcd or format the NAS as a first response.

## Validation boundary

Mocked Python tests do not validate Nix evaluation/builds, UTM bridging, physical boot, WireGuard handshakes, router rules, NFS, etcd quorum, Longhorn replication/backups, or GitHub credentials. Test those on the build host and target hardware before relying on the cluster in production.
