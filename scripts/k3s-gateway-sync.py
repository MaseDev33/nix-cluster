#!/usr/bin/env python3
"""Reconcile Kubernetes LoadBalancer/NodePort Services to atomic nftables DNAT rules."""

import argparse
import fcntl
import json
import ipaddress
import logging
import os
import subprocess
import sys

API_SERVERS = ("https://10.100.0.10:6443", "https://10.100.0.11:6443")
KUBECONFIG = "/etc/rancher/k3s/gateway.yaml"
TABLE = "k3s_gateway"
NODE_IPS = {"server-01": "10.100.0.10", "server-02": "10.100.0.11"}
ROUTE_PROTOCOL = "186"
POD_CIDR = ipaddress.ip_network("10.42.0.0/16")
WG_LOCK = "/run/lock/nix-cluster-wireguard.lock"

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
LOG = logging.getLogger("k3s-gateway-sync")


def kubectl(server, *args):
    return subprocess.run(
        [
            "kubectl",
            "--kubeconfig",
            KUBECONFIG,
            "--cache-dir=/run/k3s-gateway-sync/cache",
            "--server",
            server,
            "--request-timeout=4s",
            *args,
        ],
        check=True,
        text=True,
        capture_output=True,
    )


def fetch_snapshot():
    errors = []
    for server in API_SERVERS:
        try:
            data = {}
            for resource in ("services", "endpoints", "nodes"):
                args = ["get", resource]
                if resource != "nodes":
                    args.append("--all-namespaces")
                args.extend(["-o", "json"])
                result = kubectl(server, *args)
                data[resource] = json.loads(result.stdout)
            LOG.info("Using Kubernetes API %s", server)
            return data
        except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
            errors.append(f"{server}: {error}")
            LOG.warning("Kubernetes API %s unavailable: %s", server, error)
    raise RuntimeError("Both Kubernetes API endpoints are unavailable; preserving current nftables rules. " + "; ".join(errors))


def items(snapshot, resource):
    return snapshot.get(resource, {}).get("items", [])


def node_readiness(snapshot):
    ready = {}
    for node in items(snapshot, "nodes"):
        name = node.get("metadata", {}).get("name")
        conditions = node.get("status", {}).get("conditions", [])
        ready[name] = any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in conditions
        )
    return ready


def ready_endpoint_count(endpoint):
    return sum(
        len(subset.get("addresses", []))
        for subset in endpoint.get("subsets", [])
    )


def endpoint_target_port(service_port, endpoint, target_port, protocol):
    if target_port is None:
        target_port = service_port
    if isinstance(target_port, int):
        return target_port if 1 <= target_port <= 65535 else None
    if isinstance(target_port, str):
        return next(
            (
                endpoint_port.get("port")
                for subset in endpoint.get("subsets", [])
                for endpoint_port in subset.get("ports", [])
                if endpoint_port.get("name") == target_port
                and str(endpoint_port.get("protocol", "TCP")).lower() == protocol
                and isinstance(endpoint_port.get("port"), int)
                and 1 <= endpoint_port["port"] <= 65535
            ),
            None,
        )
    return None


def build_routes(snapshot):
    endpoints = {
        (
            endpoint.get("metadata", {}).get("namespace", "default"),
            endpoint.get("metadata", {}).get("name"),
        ): endpoint
        for endpoint in items(snapshot, "endpoints")
    }
    ready = node_readiness(snapshot)
    healthy_nodes = [name for name in NODE_IPS if ready.get(name, False)]
    if not healthy_nodes:
        LOG.warning("Neither compute node reports Ready; no new forwarding rules will be installed.")
        return []
    selected_node = healthy_nodes[0]
    routes = {}

    for service in items(snapshot, "services"):
        metadata = service.get("metadata", {})
        spec = service.get("spec", {})
        service_type = spec.get("type")
        if service_type not in {"LoadBalancer", "NodePort"}:
            continue
        namespace = metadata.get("namespace", "default")
        name = metadata.get("name", "<unnamed>")
        endpoint = endpoints.get((namespace, name))
        if endpoint is None or ready_endpoint_count(endpoint) == 0:
            LOG.info("Skipping %s/%s because it has no healthy endpoints", namespace, name)
            continue
        ready_addresses = [
            address
            for subset in endpoint.get("subsets", [])
            for address in subset.get("addresses", [])
            if address.get("ip")
            and (
                not address.get("nodeName")
                or ready.get(address.get("nodeName"), False)
            )
        ]
        if not ready_addresses:
            LOG.info("Skipping %s/%s because its ready endpoints are on unhealthy nodes", namespace, name)
            continue
        service_node = selected_node
        if spec.get("externalTrafficPolicy") == "Local":
            endpoint_nodes = {
                address.get("nodeName")
                for address in ready_addresses
                if address.get("nodeName")
            }
            local_candidates = [node for node in NODE_IPS if ready.get(node, False) and node in endpoint_nodes]
            if not local_candidates:
                LOG.info("Skipping %s/%s because Local traffic policy has no ready local endpoint", namespace, name)
                continue
            service_node = local_candidates[0]

        for port in spec.get("ports", []):
            protocol = str(port.get("protocol", "TCP")).upper().lower()
            if protocol not in {"tcp", "udp"}:
                LOG.warning("Skipping unsupported protocol %r on %s/%s", protocol, namespace, name)
                continue
            service_port = port.get("port")
            node_port = port.get("nodePort")
            if service_type == "NodePort":
                external_port = node_port
            else:
                external_port = service_port
            if not isinstance(external_port, int) or not 1 <= external_port <= 65535:
                LOG.warning("Skipping %s/%s port without a usable external or NodePort value", namespace, name)
                continue

            via_node_ip = None
            if isinstance(node_port, int) and 1 <= node_port <= 65535:
                destination_port = node_port
                destination_ip = NODE_IPS[service_node]
            else:
                service_port_target = endpoint_target_port(
                    service_port,
                    endpoint,
                    port.get("targetPort"),
                    protocol,
                )
                endpoint_address = next(
                    (
                        address
                        for node in healthy_nodes
                        for address in ready_addresses
                        if address.get("nodeName") == node
                    ),
                    None,
                )
                if (
                    service_type != "LoadBalancer"
                    or not endpoint_address
                    or not service_port_target
                ):
                    LOG.warning(
                        "Skipping %s/%s port %s: no NodePort or usable ready endpoint target",
                        namespace,
                        name,
                        external_port,
                    )
                    continue
                destination_port = service_port_target
                destination_ip = endpoint_address["ip"]
                node_name = endpoint_address.get("nodeName")
                via_node_ip = NODE_IPS.get(node_name)
                if not via_node_ip:
                    LOG.warning("Skipping %s/%s: endpoint has no known compute-node owner", namespace, name)
                    continue

            try:
                address = ipaddress.ip_address(destination_ip)
            except ValueError:
                LOG.warning("Skipping %s/%s: invalid destination address %r", namespace, name, destination_ip)
                continue
            if address.version != 4 or not isinstance(destination_port, int) or not 1 <= destination_port <= 65535:
                LOG.warning("Skipping %s/%s: invalid IPv4 destination or target port", namespace, name)
                continue

            route = {
                "protocol": protocol,
                "external_port": external_port,
                "destination_ip": destination_ip,
                "destination_port": destination_port,
                "service": f"{namespace}/{name}",
            }
            if via_node_ip:
                route["via_node_ip"] = via_node_ip
            routes.setdefault((protocol, external_port), []).append(route)

    resolved = []
    for key, candidates in sorted(routes.items()):
        targets = {
            (route["destination_ip"], route["destination_port"])
            for route in candidates
        }
        if len(targets) > 1:
            LOG.error(
                "Ambiguous external %s port %s claimed by %s; omitting it",
                key[0],
                key[1],
                ", ".join(route["service"] for route in candidates),
            )
            continue
        resolved.append(candidates[0])
    return resolved


def render_rules(routes):
    lines = [
        f"delete table inet {TABLE}",
        f"add table inet {TABLE}",
        f"add chain inet {TABLE} prerouting {{ type nat hook prerouting priority dstnat; policy accept; }}",
        f"add chain inet {TABLE} forward {{ type filter hook forward priority filter; policy drop; }}",
        f"add chain inet {TABLE} postrouting {{ type nat hook postrouting priority srcnat; policy accept; }}",
        f"add rule inet {TABLE} forward ct state established,related accept",
    ]
    for route in routes:
        proto = route["protocol"]
        external = route["external_port"]
        ip = route["destination_ip"]
        destination = route["destination_port"]
        lines.append(
            f"add rule inet {TABLE} prerouting iifname != \"wg0\" {proto} dport {external} "
            f"dnat to {ip}:{destination}"
        )
        lines.append(
            f"add rule inet {TABLE} forward oifname \"wg0\" ip daddr {ip} "
            f"{proto} dport {destination} accept"
        )
        lines.append(
            f"add rule inet {TABLE} postrouting oifname \"wg0\" ip daddr {ip} "
            f"{proto} dport {destination} snat to 10.100.0.12"
        )
    return "\n".join(lines) + "\n"


def apply_rules(rules):
    subprocess.run(["nft", "-f", "-"], input=rules, check=True, text=True, capture_output=True)


def managed_pod_routes(routes):
    return {
        f'{route["destination_ip"]}/32': route["via_node_ip"]
        for route in routes
        if route.get("via_node_ip")
        and route["destination_ip"] != route["via_node_ip"]
    }


def current_pod_routes():
    result = subprocess.run(
        ["ip", "-j", "route", "show", "proto", ROUTE_PROTOCOL, "dev", "wg0"],
        check=True,
        text=True,
        capture_output=True,
    )
    return {
        route["dst"]: route.get("gateway")
        for route in json.loads(result.stdout)
        if route.get("dst")
    }


def reconcile_pod_routes(routes, current):
    desired = managed_pod_routes(routes)
    for destination, gateway in sorted(desired.items()):
        if current.get(destination) != gateway:
            subprocess.run(
                [
                    "ip",
                    "route",
                    "replace",
                    destination,
                    "via",
                    gateway,
                    "dev",
                    "wg0",
                    "proto",
                    ROUTE_PROTOCOL,
                ],
                check=True,
                text=True,
                capture_output=True,
            )
    return desired


def remove_obsolete_pod_routes(desired, current):
    for destination in sorted(set(current) - set(desired)):
        subprocess.run(
            [
                "ip",
                "route",
                "del",
                destination,
                "dev",
                "wg0",
                "proto",
                ROUTE_PROTOCOL,
            ],
            check=True,
            text=True,
            capture_output=True,
        )


def peer_public_keys():
    keys = {}
    for node in NODE_IPS:
        path = f"/etc/wireguard/peers/{node}.pub"
        with open(path, encoding="ascii") as source:
            key = source.read().strip()
        if not key:
            raise ValueError(f"WireGuard public key file {path} is empty.")
        keys[node] = key
    return keys


def current_wireguard_allowed_ips():
    result = subprocess.run(
        ["wg", "show", "wg0", "allowed-ips"],
        check=True,
        text=True,
        capture_output=True,
    )
    return {
        fields[0]: set() if len(fields) < 2 or fields[1] == "(none)" else set(fields[1].split(","))
        for line in result.stdout.splitlines()
        if (fields := line.split())
    }


def desired_wireguard_allowed_ips(routes, current, preserve_existing):
    keys = peer_public_keys()
    node_for_ip = {address: node for node, address in NODE_IPS.items()}
    routes_by_node = {node: set() for node in NODE_IPS}
    for route in routes:
        node = node_for_ip.get(route.get("via_node_ip"))
        if node:
            routes_by_node[node].add(f'{route["destination_ip"]}/32')

    desired = {}
    for node, key in keys.items():
        allowed = {f'{NODE_IPS[node]}/32'} | routes_by_node[node]
        if preserve_existing:
            for entry in current.get(key, set()):
                try:
                    network = ipaddress.ip_network(entry, strict=False)
                except ValueError:
                    continue
                if network.version == 4 and network.prefixlen == 32 and network.network_address in POD_CIDR:
                    allowed.add(f"{network.network_address}/32")
        desired[key] = sorted(allowed)
    return desired


def reconcile_wireguard_allowed_ips(routes, preserve_existing):
    os.makedirs(os.path.dirname(WG_LOCK), exist_ok=True)
    with open(WG_LOCK, "a", encoding="ascii") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        current = current_wireguard_allowed_ips()
        desired = desired_wireguard_allowed_ips(routes, current, preserve_existing)
        for key, allowed in desired.items():
            subprocess.run(
                ["wg", "set", "wg0", "peer", key, "allowed-ips", ",".join(allowed)],
                check=True,
                text=True,
                capture_output=True,
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot-file", help="Use a JSON Kubernetes snapshot instead of contacting the API.")
    parser.add_argument("--dry-run", action="store_true", help="Print the generated nftables transaction without applying it.")
    args = parser.parse_args()
    try:
        if args.snapshot_file:
            with open(args.snapshot_file, encoding="utf-8") as source:
                snapshot = json.load(source)
        else:
            snapshot = fetch_snapshot()
        routes = build_routes(snapshot)
        rules = render_rules(routes)
        if args.dry_run:
            tables = ""
        else:
            tables = subprocess.run(
                ["nft", "list", "tables"],
                check=True,
                text=True,
                capture_output=True,
            ).stdout
        if args.dry_run:
            if f"table inet {TABLE}" not in tables:
                rules = rules.replace(f"delete table inet {TABLE}\n", "", 1)
            sys.stdout.write(rules)
        else:
            if f"table inet {TABLE}" not in tables:
                rules = rules.replace(f"delete table inet {TABLE}\n", "", 1)
            current_routes = current_pod_routes()
            reconcile_wireguard_allowed_ips(routes, preserve_existing=True)
            desired_routes = reconcile_pod_routes(routes, current_routes)
            apply_rules(rules)
            remove_obsolete_pod_routes(desired_routes, current_routes)
            reconcile_wireguard_allowed_ips(routes, preserve_existing=False)
            LOG.info("Atomically reconciled %d TCP/UDP forwarding rule(s)", len(routes))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        LOG.error("%s", error)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
