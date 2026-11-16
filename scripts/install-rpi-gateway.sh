#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
public_key=${1:-}
output_image=${2:-"${TMPDIR:-/tmp}/rpi-gateway.img"}
if [[ -z "$public_key" || ! -s "$public_key" ]]; then
  echo "Usage: $0 /path/to/lyrexo_cluster.pub [/path/to/rpi-gateway.img]" >&2
  exit 2
fi
if ! command -v nix >/dev/null; then
  echo "Nix with flakes is required. Run this from the NixOS ARM64 build VM." >&2
  exit 1
fi
for command in sudo losetup mount mountpoint realpath umount udevadm ssh-keygen; do
  command -v "$command" >/dev/null || {
    echo "Required image-provisioning command is missing: $command" >&2
    exit 1
  }
done
  public_key=$(realpath "$public_key")
  output_image=$(realpath -m "$output_image")
  ssh-keygen -l -f "$public_key" >/dev/null || {
  echo "The supplied administrator public key is invalid." >&2
  exit 1
}
cd "$repo"
store_path=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.rpi-gateway.config.system.build.sdImage)
image=$(find "$store_path" -type f -name '*.img.zst' -print -quit)
if [[ -z "$image" ]]; then
  echo "No compressed Raspberry Pi image was found under $store_path." >&2
  exit 1
fi
if [[ "$public_key" == "$output_image" ]]; then
  echo "Output image path must not overwrite the supplied public key." >&2
  exit 1
fi
if [[ -e "$output_image" ]]; then
  echo "Output image already exists; choose a new path rather than overwriting it: $output_image" >&2
  exit 1
fi
mkdir -p "$(dirname "$output_image")"
workdir=$(mktemp -d)
loop_device=
mountpoint="$workdir/root"
mkdir -p "$mountpoint"
cleanup() {
  if mountpoint -q "$mountpoint"; then sudo umount "$mountpoint"; fi
  if [[ -n "$loop_device" ]]; then sudo losetup -d "$loop_device"; fi
  rm -rf "$workdir"
}
trap cleanup EXIT
if command -v zstd >/dev/null; then
  zstd -d --force --output="$workdir/rpi-gateway.img" "$image"
else
  nix shell nixpkgs#zstd -c zstd -d --force --output="$workdir/rpi-gateway.img" "$image"
fi
loop_device=$(sudo losetup --find --show --partscan "$workdir/rpi-gateway.img")
sudo udevadm settle
root_partition="${loop_device}p2"
if [[ ! -b "$root_partition" ]]; then
  echo "Could not locate the image root partition $root_partition; no disk was written." >&2
  exit 1
fi
sudo mount "$root_partition" "$mountpoint"
sudo install -d -m 0755 "$mountpoint/home/lyrexo/.ssh"
sudo install -m 0644 "$public_key" "$mountpoint/home/lyrexo/.ssh/authorized_keys"
sudo umount "$mountpoint"
sudo losetup -d "$loop_device"
loop_device=
cp "$workdir/rpi-gateway.img" "$output_image"
printf 'Built Raspberry Pi 4 image: %s\n' "$output_image"
printf 'The image contains only the supplied public SSH key. This script never writes to a physical disk; flash it to the USB boot SSD with Raspberry Pi Imager or Etcher.\n'
