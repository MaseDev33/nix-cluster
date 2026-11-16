#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
[[ -d /mnt/etc ]] || { echo "Mount the pre-partitioned NixOS root at /mnt first." >&2; exit 1; }
echo "This installs server-01 only; it does not partition or format any disk."
exec nixos-install --flake "$repo#server-01"
