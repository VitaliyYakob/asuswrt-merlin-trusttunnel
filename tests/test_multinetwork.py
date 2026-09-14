from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_network_executor as network_tests

ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "addon/trusttunnel.sh"


def policy():
    return {
        "schema": 2,
        "networks": [
            {"lan_if": f"br{i}", "sources": [f"192.168.{50+i}.0/24"]} for i in range(4)
        ],
        "dns_ipv4": "1.1.1.1", "block_ipv6_bridge": True, "table": 871, "priority": 17100,
    }


class MultiNetworkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)

    def write(self, value):
        dest = self.path / "policy.json"; dest.write_text(json.dumps(value)); return dest

    def validate(self, value):
        return subprocess.run([str(CTL), "validate", "policy", str(self.write(value))], capture_output=True, text=True)

    def plan(self, action, value):
        result = subprocess.run([str(CTL), "plan", action, str(self.write(value))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_main_and_three_guest_networks_have_unique_priorities(self):
        rules = [x for x in self.plan("guard", policy()) if x["op"] == "rule"]
        self.assertEqual([x["interface"] for x in rules], ["br0", "br1", "br2", "br3"])
        self.assertEqual([x["priority"] for x in rules], [17100, 17101, 17102, 17103])

    def test_selected_subset_does_not_guard_other_bridges(self):
        selected = policy(); selected["networks"] = [selected["networks"][0], selected["networks"][3]]
        plan = self.plan("guard", selected)
        firewall = "\n".join(x.get("stdin", "") for x in plan)
        for bridge in ("br0", "br3"):
            self.assertIn(f"-A TTM6_FWD -i {bridge} -j REJECT", firewall)
            self.assertIn(f"-A TTM4_DNS -i {bridge}", firewall)
            self.assertIn(f"-A TTM4_FWD -i {bridge}", firewall)
        for bridge in ("br1", "br2"):
            self.assertNotIn(bridge, firewall)
        self.assertNotIn("-A TTM4_SNAT -i", firewall)  # POSTROUTING cannot match ingress -i.

    def test_multiple_sources_flatten_across_bridges_and_disarm_exactly(self):
        value = policy()
        value["networks"][1]["sources"] = ["192.168.51.7/32", "192.168.51.9/32"]
        rules = [x for x in self.plan("guard", value) if x["op"] == "rule"]
        deletes = [x["argv"] for x in self.plan("disarm", value) if x.get("argv", [])[:3] == ["ip", "-4", "rule"]]
        self.assertEqual(len(rules), 5)
        for rule, args in zip(rules, deletes):
            self.assertEqual(args, ["ip", "-4", "rule", "del", "pref", str(rule["priority"]), "from", rule["source"], "iif", rule["interface"], "lookup", "871"])

    def test_legacy_schema_produces_same_network_plan(self):
        legacy = json.loads((ROOT / "examples/policy.example.json").read_text())
        modern = {k: v for k, v in legacy.items() if k not in ("lan_if", "sources")}
        modern.update(schema=2, networks=[{"lan_if": legacy["lan_if"], "sources": legacy["sources"]}])
        for action in ("guard", "up", "down", "disarm"):
            self.assertEqual(self.plan(action, legacy), self.plan(action, modern))

    def test_rejects_invalid_networks_and_total_rule_overflow(self):
        cases = [[], None, [{"lan_if": "eth0", "sources": ["192.168.1.0/24"]}],
                 [{"lan_if": "br0", "sources": []}],
                 [{"lan_if": "br0", "sources": ["192.168.1.1/24"]}],
                 [{"lan_if": "br0", "sources": ["192.168.1.1/32"], "unexpected": True}],
                 [{"lan_if": "br0", "sources": ["192.168.1.1/32"]}] * 2,
                 [{"lan_if": f"br{i}", "sources": ["192.168.1.1/32"]} for i in range(17)],
                 [{"lan_if": "br0", "sources": [f"192.168.1.{i}/32" for i in range(1, 33)]},
                  {"lan_if": "br1", "sources": ["192.168.2.1/32"]}]]
        for networks in cases:
            with self.subTest(networks=networks):
                value = policy(); value["networks"] = networks
                self.assertNotEqual(self.validate(value).returncode, 0)

    def test_all_32_priorities_are_usable(self):
        value = policy()
        for i, network in enumerate(value["networks"]):
            network["sources"] = [f"192.168.{50+i}.{j}/32" for j in range(1, 9)]
        rules = [x for x in self.plan("guard", value) if x["op"] == "rule"]
        self.assertEqual([x["priority"] for x in rules], list(range(17100, 17132)))


class MultiNetworkExecutorTests(unittest.TestCase):
    setUp = network_tests.ExecutorTests.setUp
    execute = network_tests.ExecutorTests.execute
    state = network_tests.ExecutorTests.state
    # Reuse the filesystem-backed network harness; tests never invoke host networking.
    def execute_multi(self, body):
        config = self.path / "multinetwork.json"; config.write_text(json.dumps(policy()))
        self.env["TT_TEST_POLICY"] = str(config)
        return self.execute('cp "$TT_TEST_POLICY" "$TT_POLICY"\n' + body)

    def test_multinetwork_guard_reconcile_and_cleanup(self):
        result = self.execute_multi('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan guard "$TT_POLICY"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.state()["rules"]), 4)
        result = self.execute_multi('tt_disarm')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["rules"], [])
        self.assertFalse(any("TTM" in name for name in self.state()["chains"]))

    def test_rpf_updates_and_restores_every_selected_bridge(self):
        result = self.execute_multi('''tt_claim_resources || exit 90
for iface in br0 br1 br2 br3 br4 tt0; do
    mkdir -p "$TT_PROC/sys/net/ipv4/conf/$iface"
    printf '1\\n' >"$TT_PROC/sys/net/ipv4/conf/$iface/rp_filter"
done
tt_rpf_loose''')
        self.assertEqual(result.returncode, 0, result.stderr)
        proc = self.path / "sandbox/proc/sys/net/ipv4/conf"
        for iface in ("br0", "br1", "br2", "br3", "tt0"):
            self.assertEqual((proc / iface / "rp_filter").read_text().strip(), "2")
        self.assertEqual((proc / "br4/rp_filter").read_text().strip(), "1")
        result = self.execute_multi('tt_rpf_restore')
        self.assertEqual(result.returncode, 0, result.stderr)
        for iface in ("br0", "br1", "br2", "br3", "tt0"):
            self.assertEqual((proc / iface / "rp_filter").read_text().strip(), "1")

    def test_preflight_checks_last_bridge_and_wan_conflict(self):
        setup = '''. "$TT_BASE/lib/service.sh"
cp "$TT_BASE/../examples/endpoint.example.json" "$TT_ENDPOINT"
for iface in br0 br1 br2; do mkdir -p "$TT_SYS/class/net/$iface/bridge"; done
'''
        result = self.execute_multi(setup + 'tt_check_interfaces')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bridge does not exist", result.stderr)
        result = self.execute_multi(setup + '''mkdir -p "$TT_SYS/class/net/br3/bridge"
jq '.wan_if="br3"' "$TT_ENDPOINT" >"$TT_RUN/endpoint-test.json"
mv "$TT_RUN/endpoint-test.json" "$TT_ENDPOINT"
tt_check_interfaces''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("selected LAN bridge", result.stderr)


if __name__ == "__main__":
    unittest.main()
