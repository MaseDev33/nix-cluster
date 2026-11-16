#!/usr/bin/env python3
"""Apply the explicitly provisioned WireGuard peer keys and refresh the gateway DNS endpoint."""

import argparse
import fcntl
import ipaddress
import os
import pathlib
import socket
import subprocess
import sys

PEER_DIR = pathlib.Path("/etc/wireguard/peers")
WG_LOCK = pathlib.Path("/run/lock/nix-cluster-wireguard.lock")
POD_CIDR = ipaddress.ip_network("10.42.0.0/16")
ENDPOINT_PORT = 51820


def run(args):
    subprocess.run(args, check=True, text=True, capture_output=True)


def key_for(name):
    path = PEER_DIR / f"{name}.pub"
    if not path.is_file():
        raise FileNotFoundError(f"Missing peer public key {path}; exchange keys and provision it.")
    key = path.read_text(encoding="ascii").strip()
    if not key:
        raise ValueError(f"Peer public key file {path} is empty.")
    return key


def resolve_gateway(endpoint_host):
    addresses = sorted(
        {
            entry[4][0]
            for entry in socket.getaddrinfo(endpoint_host, ENDPOINT_PORT, socket.AF_INET, socket.SOCK_DGRAM)
        }
    )
    if not addresses:
        raise OSError(f"DNS returned no IPv4 address for {endpoint_host}.")
    return addresses[0]


def sync(role, hostname, endpoint_host):
    if role == "gateway":
        peers = {
            "server-01": ["10.100.0.10/32"],
            "server-02": ["10.100.0.11/32"],
        }
        WG_LOCK.parent.mkdir(parents=True, exist_ok=True)
        with WG_LOCK.open("a", encoding="ascii") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            current = subprocess.run(
                ["wg", "show", "wg0", "allowed-ips"],
                check=True,
                text=True,
                capture_output=True,
            ).stdout
            current_by_key = {
                fields[0]: set() if len(fields) < 2 or fields[1] == "(none)" else set(fields[1].split(","))
                for line in current.splitlines()
                if (fields := line.split())
            }
            for name, base_allowed_ips in peers.items():
                public_key = key_for(name)
                allowed_ips = set(base_allowed_ips)
                for entry in current_by_key.get(public_key, set()):
                    try:
                        network = ipaddress.ip_network(entry, strict=False)
                    except ValueError:
                        continue
                    if network.version == 4 and network.prefixlen == 32 and network.network_address in POD_CIDR:
                        allowed_ips.add(f"{network.network_address}/32")
                run(
                    [
                        "wg",
                        "set",
                        "wg0",
                        "peer",
                        public_key,
                        "allowed-ips",
                        ",".join(sorted(allowed_ips)),
                    ]
                )
        return

    if hostname not in {"server-01", "server-02"}:
        raise ValueError(f"Unsupported compute-node hostname {hostname!r}.")
    peer_key = key_for("gateway")
    other = "server-02" if hostname == "server-01" else "server-01"
    own_ip = "10.100.0.10" if hostname == "server-01" else "10.100.0.11"
    other_ip = "10.100.0.11" if hostname == "server-01" else "10.100.0.10"
    gateway_ip = resolve_gateway(endpoint_host)
    run(
        [
            "wg",
            "set",
            "wg0",
            "peer",
            peer_key,
            "allowed-ips",
            f"10.100.0.12/32,{other_ip}/32",
            "endpoint",
            f"{gateway_ip}:{ENDPOINT_PORT}",
            "persistent-keepalive",
            "25",
        ]
    )
    # Keep these checks explicit so a role/hostname mismatch cannot silently install a bad route.
    if own_ip == other_ip or other not in {"server-01", "server-02"}:
        raise ValueError("Invalid compute-node WireGuard identity.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=("gateway", "compute"), required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--endpoint-host", required=True)
    args = parser.parse_args()
    try:
        sync(args.role, args.hostname, args.endpoint_host)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"WireGuard peer reconciliation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
