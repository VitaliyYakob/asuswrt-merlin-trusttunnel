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
        script = '. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/service.sh"\n. "$TT_BASE/lib/inventory.sh"\n' + body
        return subprocess.run(["sh", "-c", script], env=self.env, text=True, capture_output=True)

    def test_sandbox_does_not_run_ip_or_nvram(self):
        result = self.execute('''ip() { echo "HOST-NETWORK-CALL" >&2; return 99; }
nvram() { echo "HOST-NVRAM-CALL" >&2; return 99; }
tt_discover_networks''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        self.assertNotIn("HOST-NETWORK-CALL", result.stderr)
        self.assertNotIn("HOST-NVRAM-CALL", result.stderr)

    def bridge(self, name, members=()):
        path = self.path / f"sys/class/net/{name}"
        (path / "bridge").mkdir(parents=True)
        (path / "brif").mkdir()
        for member in members:
            (path / "brif" / member).mkdir()

    def discover(self, values):
        (self.path / "nvram-fixture.json").write_text(json.dumps(values))
        return self.execute('''
TT_FIXTURE=$TT_ROOT
nvram() {
    [ "$1" = get ] && [ "$#" = 2 ] || return 99
    printf '%s\\n' "$2" >>"$TT_FIXTURE/nvram-keys"
    jq -r --arg key "$2" '.[$key] // ""' "$TT_FIXTURE/nvram-fixture.json"
}
ip() { printf '2: %s inet 192.168.50.1/24 scope global %s\\n' "$6" "$6"; }
TT_ROOT=
tt_discover_networks''')

    def parsed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

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
nvram() { return 99; }
TT_ROOT=
tt_discover_networks''')
        self.assertEqual(result.returncode, 0, result.stderr)
        discovered = json.loads(result.stdout)
        for network in discovered:
            self.assertRegex(network.pop('identity'), r'^[0-9a-f]{64}$')
        self.assertEqual(discovered, [
            {"lan_if": "br0", "sources": ["192.168.50.0/24"], "ssids": [], "display_name": "Локальная сеть (SSID не определён)"},
            {"lan_if": "br2", "sources": ["172.16.96.0/20"], "ssids": [], "display_name": "Локальная сеть (SSID не определён)"},
            {"lan_if": "br9.12", "sources": ["10.0.0.0/8"], "ssids": [], "display_name": "Локальная сеть (SSID не определён)"},
        ])

    def test_ssids_match_actual_bridge_members_instead_of_bridge_number(self):
        self.bridge("br0", ["eth1", "eth6", "eth7"])
        self.bridge("br3", ["wl0.1", "wl1.1"])
        self.bridge("br1", ["wl0.3"])
        rows = self.parsed(self.discover({
            "wl0_ifname": "eth6", "wl1_ifname": "eth7",
            "wl0_ssid": "Дом 2.4 GHz", "wl1_ssid": "Дом 5 GHz",
            "wl0_vifnames": "wl0.1 wl0.2 wl0.3", "wl1_vifnames": "wl1.1",
            "wl0.1_ssid": "Гости", "wl1.1_ssid": "Гости",
            "wl0.2_ssid": "Отключённая сеть", "wl0.3_ssid": "IoT",
        }))
        self.assertEqual([row["ssids"] for row in rows], [["Дом 2.4 GHz", "Дом 5 GHz"], ["IoT"], ["Гости"]])
        self.assertEqual(rows[0]["display_name"], "Дом 2.4 GHz / Дом 5 GHz")
        self.assertEqual(rows[2]["display_name"], "Гости")
        keys = (self.path / "nvram-keys").read_text().splitlines()
        self.assertNotIn("wl0.2_ssid", keys)
        self.assertTrue(all(key.endswith(("_ssid", "_ifname", "_vifnames")) for key in keys))

    def test_identity_survives_ssid_rename_but_changes_with_bridge_members(self):
        self.bridge('br1', ['wl0.1'])
        first = self.parsed(self.discover({'wl0.1_ssid':'Before'}))[0]['identity']
        renamed = self.parsed(self.discover({'wl0.1_ssid':'After'}))[0]['identity']
        self.assertEqual(first, renamed)
        (self.path/'sys/class/net/br1/brif/wl1.1').mkdir()
        changed = self.parsed(self.discover({'wl0.1_ssid':'After'}))[0]['identity']
        self.assertNotEqual(first, changed)

    def test_explicit_virtual_interface_alias_is_resolved(self):
        self.bridge("br7", ["eth6.1"])
        row = self.parsed(self.discover({"wl0_vifnames": "wl0.1", "wl0.1_ifname": "eth6.1", "wl0.1_ssid": "Guests"}))[0]
        self.assertEqual(row["ssids"], ["Guests"])

    def test_direct_wireless_member_works_when_vifnames_are_absent(self):
        self.bridge("br5", ["wl1.2"])
        row = self.parsed(self.discover({"wl1.2_ssid": "Direct guest"}))[0]
        self.assertEqual(row["ssids"], ["Direct guest"])

    def test_conflicting_alias_does_not_assume_identity(self):
        self.bridge("br1", ["wl0.1"])
        row = self.parsed(self.discover({"wl0_vifnames": "wl0.1", "wl0.1_ifname": "eth6.1", "wl0.1_ssid": "Wrong network"}))[0]
        self.assertEqual(row["ssids"], [])

    def test_ambiguous_nvram_mapping_does_not_guess_an_ssid(self):
        self.bridge("br1", ["wl0.1"])
        row = self.parsed(self.discover({
            "wl0_ifname": "wl0.1", "wl0_ssid": "Radio",
            "wl0_vifnames": "wl0.1", "wl0.1_ssid": "Guest",
        }))[0]
        self.assertEqual(row["ssids"], [])

    def test_failed_nvram_read_is_not_published_as_an_ssid(self):
        self.bridge("br1", ["wl0.1"])
        rows = self.parsed(self.execute('''
nvram() { printf 'read error\\n'; return 1; }
ip() { printf '2: br1 inet 192.168.50.1/24 scope global br1\\n'; }
TT_ROOT=
tt_discover_networks'''))
        self.assertEqual(rows[0]["ssids"], [])

    def test_ssid_json_preserves_quotes_unicode_and_newlines(self):
        self.bridge("br2", ["wl0.1", "wl1.1"])
        names = ['Гости "VIP" \\ & <script>', "Сеть\nс переводом строки\n"]
        row = self.parsed(self.discover({"wl0.1_ssid": names[0], "wl1.1_ssid": names[1]}))[0]
        self.assertEqual(row["ssids"], sorted(names))

    def test_wired_or_unknown_bridge_has_explicit_friendly_fallback(self):
        self.bridge("br0", ["eth1"])
        self.bridge("br1")
        rows = self.parsed(self.discover({"wl0_ifname": "eth6", "wl0_ssid": "Unrelated radio"}))
        for row in rows:
            self.assertEqual(row["ssids"], [])
            self.assertEqual(row["display_name"], "Локальная сеть (SSID не определён)")

    def test_untrusted_vifnames_cannot_select_unrelated_nvram_keys(self):
        self.bridge("br0", ["eth1"])
        self.parsed(self.discover({"wl0_vifnames": "* wl1.1 wl0.1_wpa_psk ../../evil"}))
        keys = (self.path / "nvram-keys").read_text().splitlines()
        self.assertFalse(any("wpa_psk" in key or "evil" in key or "*" in key for key in keys))

    def test_status_falls_back_to_empty_inventory_on_ip_failure(self):
        (self.path / "sys/class/net/br0/bridge").mkdir(parents=True)
        result = self.execute('ip() { return 99; }\nnvram() { return 99; }\nTT_ROOT=\ntt_status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["discovered_networks"], [])

    def test_parser_ignores_malformed_addresses_and_deduplicates_networks(self):
        result = subprocess.run(["jq", "-Rn", "--arg", "interface", "br0", "-f", str(ROOT / "addon/share/inventory.jq")],
                                input="192.168.50.1/24\n192.168.50.2/24\n999.1.1.1/24\n192.168.1.1/33\nmalformed\n", text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"lan_if": "br0", "sources": ["192.168.50.0/24"]})


if __name__ == "__main__":
    unittest.main()
