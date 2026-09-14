"""Offline regressions for configuration-owned DNS and legacy policy migration."""
from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "addon/trusttunnel.sh"
ENDPOINT = json.loads((ROOT / "examples/endpoint.example.json").read_text())
TRANSIT = "192.0.2.53"


def modern_policy():
    return {"schema": 3, "networks": [{"lan_if": "br1", "sources": ["192.168.51.0/24"]}],
            "block_ipv6_bridge": True, "table": 871, "priority": 17100}


def legacy_policy(schema):
    value = modern_policy() | {"schema": schema, "dns_ipv4": "8.8.8.8"}
    if schema == 1:
        value.update(value.pop("networks")[0])
    return value


class DnsConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = os.environ | {"TT_ROOT": str(self.path / "sandbox"), "TT_BASE": str(ROOT / "addon")}
        self.config = self.path / "sandbox/jffs/addons/trusttunnel/config"

    def write(self, value, name="input.json"):
        path = self.path / name
        path.write_text(json.dumps(value))
        return path

    def cli(self, *args):
        return subprocess.run([str(CTL), *map(str, args)], capture_output=True, text=True, env=self.env)

    def shell(self, script, *args):
        prefix = '. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/config.sh"\ntt_dirs || exit 91\n'
        return subprocess.run(["sh", "-c", prefix + script, "dns-test", *map(str, args)],
                              capture_output=True, text=True, env=self.env)

    def test_dns_transports_and_ports_survive_import_and_toml_render(self):
        upstreams = ["https://dns.example.test/custom?profile=synthetic", "tls://dns.example.test:8853",
                     "quic://dns.example.test:8853", "9.9.9.9:5353"]
        source = self.write(ENDPOINT | {"dns_upstreams": upstreams})
        result = self.cli("import-endpoint", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli("render", self.config / "endpoint.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = tomllib.loads(result.stdout)
        self.assertEqual(rendered["endpoint"]["dns_upstreams"], upstreams)
        self.assertNotIn("dns_upstreams", rendered)
        self.assertNotIn(TRANSIT, result.stdout)

    def test_empty_dns_is_preserved_but_runtime_refuses_without_changing_previous_toml(self):
        source = self.write(ENDPOINT | {"dns_upstreams": []})
        result = self.cli("import-endpoint", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli("render", self.config / "endpoint.json")
        self.assertEqual(tomllib.loads(result.stdout)["endpoint"]["dns_upstreams"], [])
        result = self.shell('printf "previous runtime" >"$TT_RUN/client.toml"\ntt_render_runtime')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("configuration has no DNS upstreams", result.stderr)
        self.assertNotIn(ENDPOINT["password"], result.stdout + result.stderr)
        runtime = self.path / "sandbox/tmp/trusttunnel/client.toml"
        self.assertEqual(runtime.read_text(), "previous runtime")

    def test_missing_null_and_whitespace_dns_fail_validation_without_disclosure(self):
        for value in (None, "tls://dns.example.test", ["tls://dns.example.test secret"]):
            result = self.cli("validate", "endpoint", self.write(ENDPOINT | {"dns_upstreams": value}))
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("secret", result.stdout + result.stderr)
        missing = dict(ENDPOINT)
        del missing["dns_upstreams"]
        self.assertNotEqual(self.cli("validate", "endpoint", self.write(missing)).returncode, 0)

    def test_schema3_has_no_second_resolver_and_preserves_source_scope(self):
        result = self.cli("plan", "guard", self.write(modern_policy()))
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        firewall = "\n".join(item.get("stdin", "") for item in plan)
        for protocol in ("udp", "tcp"):
            self.assertIn(f"-A TTM4_DNS -i br1 -s 192.168.51.0/24 -p {protocol} --dport 53 -j DNAT --to-destination {TRANSIT}:53", firewall)
        self.assertEqual(firewall.count("--to-destination"), 2)
        self.assertNotIn("1.1.1.1", firewall)
        self.assertNotIn("8.8.8.8", firewall)
        # No original destination match: requests sent to the router are captured too.
        self.assertFalse(any(" -d " in line for line in firewall.splitlines() if line.startswith("-A TTM4_DNS ")))
        self.assertNotEqual(self.cli("validate", "policy", self.write(modern_policy() | {"dns_ipv4": "8.8.8.8"})).returncode, 0)

    def test_legacy_plans_do_not_use_or_depend_on_obsolete_resolver(self):
        reference = self.cli("plan", "guard", self.write(modern_policy())).stdout
        for schema in (1, 2):
            for obsolete_dns in ("8.8.8.8", "9.9.9.9"):
                result = self.cli("plan", "guard", self.write(legacy_policy(schema) | {"dns_ipv4": obsolete_dns}))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, reference)

    def test_legacy_import_migrates_only_after_private_backup_and_restores_reversibly(self):
        for schema in (1, 2):
            with self.subTest(schema=schema):
                old = legacy_policy(schema)
                old_file = self.write(old, "old.json")
                new = modern_policy()
                new["networks"][0]["sources"] = ["192.168.51.7/32"]
                new_file = self.write(new, "new.json")
                result = self.shell('cp "$1" "$TT_POLICY"\nchmod 600 "$TT_POLICY"\ntt_import policy "$2"', old_file, new_file)
                self.assertEqual(result.returncode, 0, result.stderr)
                saved = self.config / "policy.json"
                backup = self.config / "policy.json.previous"
                self.assertEqual(json.loads(saved.read_text()), new)
                self.assertEqual(json.loads(backup.read_text()), old)
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                result = self.cli("import-policy", backup)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(saved.read_text()), modern_policy())
                self.assertEqual(json.loads(backup.read_text()), new)

    def test_enabled_legacy_policy_cannot_be_rewritten_by_import(self):
        old_file = self.write(legacy_policy(1))
        result = self.shell('cp "$1" "$TT_POLICY"\n: >"$TT_ENABLED"\ntt_import policy "$1"', old_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads((self.config / "policy.json").read_text()), legacy_policy(1))
        self.assertFalse((self.config / "policy.json.previous").exists())

    def test_legacy_migration_backup_failure_preserves_config_bytes(self):
        old_file = self.write(legacy_policy(2))
        new_file = self.write(modern_policy(), "new.json")
        result = self.shell('cp "$1" "$TT_POLICY"\nmkdir "$TT_POLICY.previous"\ntt_import policy "$2"', old_file, new_file)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.config / "policy.json").read_bytes(), old_file.read_bytes())


class DnsConverterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("convert_dns_config", ROOT / "tools/convert-config.py")
        cls.converter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.converter)

    def test_converter_preserves_endpoint_empty_over_legacy_and_never_invents_dns(self):
        base = {"hostname": "vpn.example.test", "addresses": ["203.0.113.1:443"],
                "username": "fixture-user", "password": "fixture-password"}
        for source in ({"endpoint": base}, {"endpoint": base | {"dns_upstreams": []}},
                       {"endpoint": base | {"dns_upstreams": []}, "dns_upstreams": ["9.9.9.9"]}):
            self.assertEqual(self.converter.convert(copy.deepcopy(source))["dns_upstreams"], [])
        legacy = ["https://dns.example.test/dns-query"]
        self.assertEqual(self.converter.convert({"endpoint": base, "dns_upstreams": legacy})["dns_upstreams"], legacy)
        endpoint_dns = ["tls://dns.example.test:8853"]
        self.assertEqual(self.converter.convert({"endpoint": base | {"dns_upstreams": endpoint_dns}, "dns_upstreams": legacy})["dns_upstreams"], endpoint_dns)


if __name__ == "__main__":
    unittest.main()
