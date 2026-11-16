#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
[[ -d /mnt/etc ]] || { echo "Mount the pre-partitioned UTM guest root at /mnt first." >&2; exit 1; }
echo "This installs the NixOS guest server-02; it does not modify macOS or partition a disk."
exec nixos-install --flake "$repo#server-02"
