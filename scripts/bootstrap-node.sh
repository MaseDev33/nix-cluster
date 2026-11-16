#!/usr/bin/env bash
set -euo pipefail

role=${1:-}
public_key=${2:-}
case "$role" in
  server-01|server-02|rpi-gateway) ;;
  *)
    echo "Usage: $0 {server-01|server-02|rpi-gateway} /path/to/lyrexo.pub" >&2
    exit 2
    ;;
esac
if [[ -z "$public_key" || ! -s "$public_key" ]]; then
  echo "A readable administrator SSH public-key file is required." >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  if [[ "$role" != rpi-gateway || "$(id -un)" != lyrexo ]]; then
    echo "Run this script as root on the target NixOS system." >&2
    exit 1
  fi
  passwd lyrexo
  exec sudo env NIX_CLUSTER_PASSWORD_SET=1 bash "$0" "$role" "$public_key"
fi
for command in wg passwd install; do
  command -v "$command" >/dev/null || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

install -d -m 0700 /etc/wireguard /etc/wireguard/peers
if [[ ! -s /etc/wireguard/private.key ]]; then
  wg genkey > /etc/wireguard/private.key
  chmod 0600 /etc/wireguard/private.key
fi
wg pubkey < /etc/wireguard/private.key

authorized_keys=/home/lyrexo/.ssh/authorized_keys
install -d -m 0700 -o lyrexo -g users "$(dirname "$authorized_keys")"
if [[ "$public_key" -ef "$authorized_keys" ]]; then
  chown lyrexo:users "$authorized_keys"
  chmod 0600 "$authorized_keys"
else
  install -m 0600 -o lyrexo -g users "$public_key" "$authorized_keys"
fi

if [[ "$role" == server-01 ]]; then
  if [[ ! -s /etc/k3s-token ]]; then
    if command -v openssl >/dev/null; then
      openssl rand -hex 32 | tr -d '\n' > /etc/k3s-token
    else
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/k3s-token
    fi
    chmod 0600 /etc/k3s-token
  fi
  echo "Copy /etc/k3s-token securely to server-02; do not commit or print it."
elif [[ "$role" == server-02 ]]; then
  if [[ ! -s /etc/k3s-token ]]; then
    read -r -s -p "Paste the server-01 K3s token: " token
    printf '\n'
    if [[ -z "$token" ]]; then
      echo "The K3s token cannot be empty." >&2
      exit 1
    fi
    printf '%s' "$token" > /etc/k3s-token
    chmod 0600 /etc/k3s-token
    unset token
  fi
fi

if [[ ${NIX_CLUSTER_PASSWORD_SET:-0} != 1 ]]; then
  echo "Set the password for the lyrexo administrator account:"
  passwd lyrexo
fi
echo "Provision /etc/wireguard/peers/*.pub using the exchanged peer public keys."
echo "Then rebuild the node configuration and verify the WireGuard handshake."
