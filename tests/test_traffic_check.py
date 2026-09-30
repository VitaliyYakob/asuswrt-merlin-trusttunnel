"""Traffic observations are mocked, never a hardware leak test."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class TrafficCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)

    def shell(self,body):
        return subprocess.run(['busybox','ash','-c','''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/traffic-check.sh"
tt_dirs || exit 90
'''+body],capture_output=True,text=True,env=os.environ|{'TT_ROOT':str(self.path),'TT_BASE':str(ROOT/'addon')})

    def test_sandbox_refuses_live_queries(self):
        r=self.shell('ip() { echo HOST_CALL >&2; }; iptables() { echo HOST_CALL >&2; }; tt_tunnel_addresses; tt_verify_traffic')
        self.assertNotEqual(r.returncode,0); self.assertNotIn('HOST_CALL',r.stdout+r.stderr)
        self.assertEqual(r.stdout.strip(),'[]')

    def observation(self,before,after,guard=True):
        body=f'''# Explicit mocks after common.sh's PATH; no host networking.
tt_live() {{ return 0; }}
tt_pid_matches() {{ return 0; }}
tt_check_guard_rules() {{ return {0 if guard else 1}; }}
: >"$TT_ENABLED"
printf '42' >"$TT_RUN/client.start"
printf '%s' '{json.dumps(before)}' >"$TT_RUN/sample"
tt_packet_snapshot() {{ cat "$TT_RUN/sample"; }}
sleep() {{ printf '%s' '{json.dumps(after)}' >"$TT_RUN/sample"; }}
tt_verify_traffic && tt_traffic_check_status
'''
        r=self.shell(body); self.assertEqual(r.returncode,0,r.stderr); return json.loads(r.stdout)

    def test_both_directions_are_observation_not_leak_proof(self):
        report=self.observation(dict(sent=1,received=2),dict(sent=3,received=4))
        self.assertEqual(report['state'],'traffic_observed')
        self.assertTrue(report['rules_checked']); self.assertFalse(report['leak_test_verified'])

    def test_idle_or_one_direction_never_claims_connection(self):
        for after in [dict(sent=0,received=0),dict(sent=3,received=0)]:
            self.assertEqual(self.observation(dict(sent=0,received=0),after)['state'],'idle')

    def test_missing_rule_is_reported_even_with_traffic(self):
        self.assertEqual(self.observation(dict(sent=1,received=1),dict(sent=4,received=4),False)['state'],'incomplete')

    def test_counter_reset_is_not_negative_success(self):
        self.assertEqual(self.observation(dict(sent=100,received=100),dict(sent=1,received=1))['state'],'counters_reset')

    def test_result_invalidates_after_restart_or_configuration_change(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        r=self.shell('printf 43 >"$TT_RUN/client.start"; tt_traffic_check_status')
        self.assertEqual(json.loads(r.stdout),None)
        r=self.shell('printf 42 >"$TT_RUN/client.start"; printf 0123456789abcdef >"$TT_CONFIG/revision"; tt_traffic_check_status')
        self.assertEqual(json.loads(r.stdout),None)

    def test_snapshot_counts_only_accept_to_from_tunnel(self):
        r=self.shell('''iptables() { cat <<'TABLE'
Chain TTM4_FWD
 pkts bytes target prot opt in out source destination
 4 100 ACCEPT all -- br1 tt0 192.168.50.0/24 0.0.0.0/0
 3 100 ACCEPT all -- tt0 br1 0.0.0.0/0 192.168.50.0/24
 99 100 SKIPLOG all -- br1 * 192.168.50.0/24 0.0.0.0/0
 99 100 REJECT all -- br1 * 192.168.50.0/24 0.0.0.0/0
TABLE
}
tt_packet_snapshot''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout),dict(sent=4,received=3))

    def test_each_guard_rule_checked_and_host_rule_normalized(self):
        body='''cp "$TT_BASE/../examples/policy.example.json" "$TT_POLICY"
jq '.sources=["192.168.50.10/32"]' "$TT_POLICY" >"$TT_RUNTIME_POLICY"
cp "$TT_RUNTIME_POLICY" "$TT_POLICY"; : >"$TT_OWNED"
tt_guard_state() { printf installed_unverified; }
ip() {
 case " $* " in
 *" route show "*) printf 'default dev tt0 scope link metric 10\nprohibit default metric 32760\n';;
 *" rule show "*) printf '17100: from 192.168.50.10 iif br1 lookup 871\n';;
 *) echo MUTATION >&2; return 99;; esac
}
iptables() { case " $* " in *" -C "*) return 0;; *) echo MUTATION >&2; return 99;; esac; }
ip6tables() { iptables "$@"; }
tt_check_guard_rules
'''
        r=self.shell(body);self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('MUTATION',r.stderr)
        r=self.shell(body.replace('ip6tables() { iptables "$@"; }','ip6tables() { return 1; }'))
        self.assertNotEqual(r.returncode,0)
