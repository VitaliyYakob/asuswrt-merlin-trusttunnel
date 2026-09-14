from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NetworkInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = os.environ | {"TT_ROOT": str(self.path), "TT_BASE": str(ROOT / "addon")}

    def execute(self, body):
        script = '. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/service.sh"\n' + body
        return subprocess.run(["sh", "-c", script], env=self.env, text=True, capture_output=True)

    def test_sandbox_does_not_run_ip(self):
        result = self.execute('ip() { echo "HOST-NETWORK-CALL" >&2; return 99; }\ntt_discover_networks')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        self.assertNotIn("HOST-NETWORK-CALL", result.stderr)

    def test_discovers_only_real_bridge_directories_and_normalizes_prefixes(self):
        for interface in ("br0", "br2", "br9.12", "eth0"):
            (self.path / f"sys/class/net/{interface}/bridge").mkdir(parents=True)
        (self.path / "sys/class/net/br5").mkdir()
        result = self.execute('''ip() {
case "$6" in
br0) printf '2: br0 inet 192.168.50.1/24 brd 192.168.50.255 scope global br0\\n';;
br2) printf '3: br2 inet 172.16.99.4/20 scope global br2\\n';;
br9.12) printf '4: br9.12 inet 10.0.0.1/8 scope global br9.12\\n';;
*) return 99;;
esac
}
TT_ROOT=
tt_discover_networks''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            {"lan_if": "br0", "sources": ["192.168.50.0/24"]},
            {"lan_if": "br2", "sources": ["172.16.96.0/20"]},
            {"lan_if": "br9.12", "sources": ["10.0.0.0/8"]},
        ])

    def test_status_falls_back_to_empty_inventory_on_ip_failure(self):
        (self.path / "sys/class/net/br0/bridge").mkdir(parents=True)
        result = self.execute('ip() { return 99; }\nTT_ROOT=\ntt_status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["discovered_networks"], [])

    def test_parser_ignores_malformed_addresses_and_deduplicates_networks(self):
        result = subprocess.run(["jq", "-Rn", "--arg", "interface", "br0", "-f", str(ROOT / "addon/share/inventory.jq")],
                                input="192.168.50.1/24\n192.168.50.2/24\n999.1.1.1/24\n192.168.1.1/33\nmalformed\n", text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"lan_if": "br0", "sources": ["192.168.50.0/24"]})


if __name__ == "__main__":
    unittest.main()
