#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root on the target NixOS system." >&2
  exit 1
fi
source_key=${1:-}
if [[ -z "$source_key" || ! -s "$source_key" ]]; then
  echo "Usage: $0 /path/to/administrator.pub" >&2
  exit 2
fi
authorized_keys=/home/lyrexo/.ssh/authorized_keys
install -d -m 0700 -o lyrexo -g users "$(dirname "$authorized_keys")"
if [[ "$source_key" -ef "$authorized_keys" ]]; then
  chown lyrexo:users "$authorized_keys"
  chmod 0600 "$authorized_keys"
else
  install -m 0600 -o lyrexo -g users "$source_key" "$authorized_keys"
fi
echo "Installed administrator public key at $authorized_keys."
