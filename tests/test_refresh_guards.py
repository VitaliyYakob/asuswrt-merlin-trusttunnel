from __future__ import annotations

import unittest

import test_network_executor as network_tests


class RefreshGuardTests(unittest.TestCase):
    setUp = network_tests.ExecutorTests.setUp
    execute = network_tests.ExecutorTests.execute
    state = network_tests.ExecutorTests.state

    def refresh(self, pause=False, fail=""):
        paused = ': >"$TT_PAUSED"' if pause else ""
        # Override live admission and client prerequisites; all networking still
        # uses the existing command recorder, installed after common.sh's PATH.
        body = '''. "$TT_BASE/lib/service.sh"
tt_live() { return 0; }
tt_preflight() { : >"$TT_RUN/preflight-called"; return 1; }
tt_spawn() { : >"$TT_RUN/spawn-called"; return 0; }
: >"$TT_ENABLED"
''' + paused + '\ntt_refresh'
        return self.execute(body, fail=fail)

    def test_client_preflight_failure_does_not_prevent_firewall_restore(self):
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        state = self.state()
        self.assertIn("iptables:filter:TTM4_FWD", state["chains"])
        self.assertIn("ip6tables:filter:TTM6_FWD", state["chains"])
        self.assertIn("871:32760", state["routes"])
        self.assertEqual(len(state["rules"]), 1)
        self.assertTrue((self.path / "sandbox/jffs/addons/trusttunnel/config/enabled").exists())
        self.assertTrue((self.path / "sandbox/tmp/trusttunnel/preflight-called").exists())
        self.assertFalse((self.path / "sandbox/tmp/trusttunnel/spawn-called").exists())

    def test_paused_refresh_restores_guards_without_client_preflight(self):
        result = self.refresh(pause=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("iptables:filter:TTM4_FWD", self.state()["chains"])
        self.assertIn("871:32760", self.state()["routes"])
        self.assertTrue((self.path / "sandbox/jffs/addons/trusttunnel/config/paused").exists())
        self.assertFalse((self.path / "sandbox/tmp/trusttunnel/preflight-called").exists())
        self.assertFalse((self.path / "sandbox/tmp/trusttunnel/spawn-called").exists())

    def test_guard_failure_keeps_enabled_intent_and_prevents_spawn(self):
        result = self.refresh(fail="ip6tables-restore")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.path / "sandbox/jffs/addons/trusttunnel/config/enabled").exists())
        self.assertFalse((self.path / "sandbox/tmp/trusttunnel/preflight-called").exists())
        self.assertFalse((self.path / "sandbox/tmp/trusttunnel/spawn-called").exists())

    def test_backoff_skips_client_retry_but_reinstalls_guards(self):
        result = self.execute('''
. "$TT_BASE/lib/service.sh"
tt_live() { return 0; }
tt_preflight() { echo unexpected >&2; return 99; }
: >"$TT_ENABLED"
jq -n --argjson timer "$(tt_timer 900)" '{failures:5,timer:$timer}' >"$TT_RUN/retry.json"
tt_refresh''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('unexpected', result.stderr)
        self.assertIn('871:32760', self.state()['routes'])
        self.assertIn('ip6tables:filter:TTM6_FWD', self.state()['chains'])


if __name__ == "__main__":
    unittest.main()
