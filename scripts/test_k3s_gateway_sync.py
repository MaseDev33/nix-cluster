import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

SCRIPT = pathlib.Path(__file__).with_name("k3s-gateway-sync.py")
SPEC = importlib.util.spec_from_file_location("gateway_sync", SCRIPT)
gateway = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gateway)


def service(name, service_type, ports):
    return {
        "metadata": {"namespace": "apps", "name": name},
        "spec": {"type": service_type, "ports": ports},
    }


def endpoint(name, ready=True, node_name=None):
    return {
        "metadata": {"namespace": "apps", "name": name},
        "subsets": [{
            "addresses": [
                {"ip": "10.42.0.5", **({"nodeName": node_name} if node_name else {})}
            ] if ready else [],
            "ports": [{"port": 8080}],
        }],
    }


def node(name, ready):
    return {
        "metadata": {"name": name},
        "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]},
    }


class GatewaySyncTests(unittest.TestCase):
    def snapshot(self, services, endpoints, primary=True, secondary=True):
        return {
            "services": {"items": services},
            "endpoints": {"items": endpoints},
            "nodes": {"items": [node("server-01", primary), node("server-02", secondary)]},
        }

    def test_load_balancer_service_port_maps_to_node_port(self):
        data = self.snapshot(
            [service("web", "LoadBalancer", [{"port": 443, "nodePort": 31443, "protocol": "TCP"}])],
            [endpoint("web")],
        )
        routes = gateway.build_routes(data)
        self.assertEqual(routes[0]["external_port"], 443)
        self.assertEqual(routes[0]["destination_port"], 31443)
        self.assertEqual(routes[0]["destination_ip"], "10.100.0.10")

    def test_nodeport_uses_nodeport_on_healthy_failover_node(self):
        data = self.snapshot(
            [service("voice", "NodePort", [{"port": 5060, "nodePort": 32060, "protocol": "UDP"}])],
            [endpoint("voice")],
            primary=False,
            secondary=True,
        )
        routes = gateway.build_routes(data)
        self.assertEqual(routes[0]["external_port"], 32060)
        self.assertEqual(routes[0]["destination_ip"], "10.100.0.11")

    def test_services_without_healthy_endpoints_are_not_exposed(self):
        data = self.snapshot(
            [service("empty", "LoadBalancer", [{"port": 80, "nodePort": 30080}])],
            [endpoint("empty", ready=False)],
        )
        self.assertEqual(gateway.build_routes(data), [])

    def test_local_traffic_policy_selects_node_with_ready_endpoint(self):
        local_service = service(
            "local",
            "NodePort",
            [{"port": 8080, "nodePort": 32080, "protocol": "TCP"}],
        )
        local_service["spec"]["externalTrafficPolicy"] = "Local"
        data = self.snapshot([local_service], [endpoint("local", node_name="server-02")])
        routes = gateway.build_routes(data)
        self.assertEqual(routes[0]["destination_ip"], "10.100.0.11")

    def test_load_balancer_without_nodeport_uses_healthy_named_target_port(self):
        load_balancer = service(
            "direct",
            "LoadBalancer",
            [{"port": 80, "targetPort": "web", "protocol": "TCP"}],
        )
        endpoint_object = endpoint("direct", node_name="server-02")
        endpoint_object["subsets"][0]["ports"] = [{"name": "web", "port": 8080, "protocol": "TCP"}]
        data = self.snapshot([load_balancer], [endpoint_object])
        routes = gateway.build_routes(data)
        self.assertEqual(routes[0]["external_port"], 80)
        self.assertEqual(routes[0]["destination_port"], 8080)
        self.assertEqual(routes[0]["destination_ip"], "10.42.0.5")
        self.assertEqual(routes[0]["via_node_ip"], "10.100.0.11")

    def test_direct_pod_route_is_allowed_to_its_wireguard_peer(self):
        routes = [{
            "destination_ip": "10.42.0.5",
            "via_node_ip": "10.100.0.11",
        }]
        with mock.patch.object(
            gateway,
            "peer_public_keys",
            return_value={"server-01": "key01", "server-02": "key02"},
        ):
            allowed = gateway.desired_wireguard_allowed_ips(routes, {}, False)
        self.assertEqual(allowed["key01"], ["10.100.0.10/32"])
        self.assertEqual(allowed["key02"], ["10.100.0.11/32", "10.42.0.5/32"])

    def test_rules_are_a_single_nftables_transaction(self):
        data = self.snapshot(
            [service("web", "LoadBalancer", [{"port": 80, "nodePort": 30080}])],
            [endpoint("web")],
        )
        rules = gateway.render_rules(gateway.build_routes(data))
        self.assertIn("dnat to 10.100.0.10:30080", rules)
        self.assertIn("snat to 10.100.0.12", rules)
        self.assertIn('iifname != "wg0"', rules)
        self.assertTrue(rules.startswith("delete table inet k3s_gateway\n"))
        self.assertIn("policy drop", rules)

    def test_api_query_falls_back_to_secondary_server(self):
        response = self.snapshot([], [])

        def fake_kubectl(server, *args):
            if server == gateway.API_SERVERS[0]:
                raise subprocess.CalledProcessError(1, args, stderr="unavailable")
            return SimpleNamespace(stdout=json.dumps(response[args[1]]))

        with mock.patch.object(gateway, "kubectl", side_effect=fake_kubectl):
            self.assertEqual(gateway.fetch_snapshot(), response)

    def test_unavailable_apis_do_not_apply_new_rules(self):
        with (
            mock.patch.object(sys, "argv", ["k3s-gateway-sync"]),
            mock.patch.object(gateway, "fetch_snapshot", side_effect=RuntimeError("both down")),
            mock.patch.object(gateway, "apply_rules") as apply_rules,
        ):
            self.assertEqual(gateway.main(), 1)
            apply_rules.assert_not_called()


if __name__ == "__main__":
    unittest.main()
