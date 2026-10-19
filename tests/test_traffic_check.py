"""Traffic observations are mocked, never a hardware leak test."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class TrafficCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.config=self.path/'jffs/addons/trusttunnel/config'
        self.run=self.path/'tmp/trusttunnel'
        boot=self.path/'proc/sys/kernel/random/boot_id'
        boot.parent.mkdir(parents=True); boot.write_text('fixture-boot\n')
        (self.path/'proc/uptime').write_text('1000.0 0.0\n')

    def shell(self,body):
        return subprocess.run(['busybox','ash','-c','''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/traffic-check.sh"
tt_dirs || exit 90
date() { printf '1800000000\n'; }
'''+body],capture_output=True,text=True,env=os.environ|{'TT_ROOT':str(self.path),'TT_BASE':str(ROOT/'addon')})

    def history(self,body=''):
        result=self.shell('tt_pid_matches() { return 0; }\n'+body+'\ntt_traffic_check_history')
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)

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
        self.assertTrue(self.history()['fresh'])
        self.assertIsNone(self.history()['stale_reason'])
        self.assertEqual((self.config/'traffic-check.json').stat().st_mode & 0o777,0o600)

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
        self.assertEqual(self.history()['stale_reason'],'client_restarted')
        r=self.shell('printf 42 >"$TT_RUN/client.start"; printf 0123456789abcdef >"$TT_CONFIG/revision"; tt_traffic_check_status')
        self.assertEqual(json.loads(r.stdout),None)
        history=self.history()
        self.assertEqual(history['stale_reason'],'settings_changed')
        self.assertEqual(history['state'],'traffic_observed')
        self.assertFalse(history['fresh'])

    def test_expiry_keeps_history_without_publishing_current_proof(self):
        self.observation(dict(sent=1,received=2),dict(sent=3,received=5))
        (self.path/'proc/uptime').write_text('1300.0 0.0\n')
        history=self.history()
        self.assertEqual(history['stale_reason'],'expired')
        self.assertFalse(history['fresh'])
        self.assertEqual(history['checked_at'],1800000000)
        self.assertEqual((history['sent_packets'],history['received_packets']),(2,3))
        r=self.shell('tt_pid_matches() { return 0; }; tt_traffic_check_status')
        self.assertIsNone(json.loads(r.stdout))

    def test_history_survives_runtime_loss_and_detects_new_boot(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        shutil.rmtree(self.run)
        (self.path/'proc/sys/kernel/random/boot_id').write_text('next-boot\n')
        history=self.history()
        self.assertEqual(history['state'],'traffic_observed')
        self.assertEqual(history['stale_reason'],'router_restarted')
        self.assertFalse(history['fresh'])

    def test_pause_or_disable_keeps_previous_result_as_history(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        history=self.history(': >"$TT_PAUSED"')
        self.assertEqual(history['stale_reason'],'client_stopped')
        self.assertFalse(history['fresh'])
        history=self.history('rm -f "$TT_PAUSED" "$TT_ENABLED"')
        self.assertEqual(history['stale_reason'],'client_stopped')
        self.assertEqual(history['state'],'traffic_observed')

    def test_calendar_jump_does_not_extend_or_expire_monotonic_check(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        for epoch in (1700000000,1900000000):
            with self.subTest(epoch=epoch):
                self.assertTrue(self.history(f'date() {{ printf "{epoch}\\n"; }}')['fresh'])
        (self.path/'proc/uptime').write_text('1300.0 0.0\n')
        self.assertFalse(self.history('date() { printf "1700000000\\n"; }')['fresh'])

    def test_legacy_history_migrates_once_without_becoming_fresh(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        report=json.loads((self.config/'traffic-check.json').read_text())
        del report['timer']
        (self.run/'traffic-check.json').write_text(json.dumps(report))
        (self.config/'traffic-check.json').unlink()
        history=self.history()
        self.assertEqual(history['stale_reason'],'legacy')
        self.assertFalse(history['fresh'])
        self.assertFalse((self.config/'traffic-check.json').exists(),'read-only collection must not migrate files')
        result=self.shell('tt_preserve_traffic_check')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.config/'traffic-check.json').read_text()),report)
        self.assertEqual((self.config/'traffic-check.json').stat().st_mode & 0o777,0o600)
        (self.run/'traffic-check.json').write_text('{}')
        self.assertEqual(self.shell('tt_preserve_traffic_check').returncode,0)
        self.assertEqual(json.loads((self.config/'traffic-check.json').read_text()),report)
        shutil.rmtree(self.run)
        self.assertEqual(self.history()['state'],'traffic_observed')

    def test_old_legacy_result_is_expired_but_visible(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        report=json.loads((self.config/'traffic-check.json').read_text())
        del report['timer']; report['checked_at']-=300
        (self.config/'traffic-check.json').write_text(json.dumps(report))
        self.assertEqual(self.history()['stale_reason'],'expired')

    def test_no_record_and_corrupted_record_are_not_success(self):
        self.assertIsNone(self.history())
        for content in ('{','null','{}','[]','{}\n{}'):
            with self.subTest(content=content):
                (self.config/'traffic-check.json').write_text(content)
                self.assertIsNone(self.history())

    def test_history_publishes_only_observation_fields(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        report=json.loads((self.config/'traffic-check.json').read_text())
        report['password']='synthetic-private-value'
        (self.config/'traffic-check.json').write_text(json.dumps(report))
        self.assertNotIn('password',self.history())
        self.assertNotIn('synthetic-private-value',json.dumps(self.history()))

    def test_corrupted_timer_is_not_current_proof(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        report=json.loads((self.config/'traffic-check.json').read_text())
        for timer in (False,'invalid',{'boot_id':'fixture-boot'},dict(boot_id='fixture-boot',started=1000,deadline=999999)):
            with self.subTest(timer=timer):
                report['timer']=timer
                (self.config/'traffic-check.json').write_text(json.dumps(report))
                self.assertIsNone(self.history())

    def test_publication_migrates_legacy_history_without_advancing_settings(self):
        self.observation(dict(sent=1,received=1),dict(sent=2,received=2))
        shutil.move(self.config/'traffic-check.json',self.run/'traffic-check.json')
        (self.config/'revision').write_text('0123456789abcdef')
        result=self.shell('''. "$TT_BASE/lib/service.sh"
tt_status() { printf '{}\\n'; }
tt_publish_status''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.config/'traffic-check.json').exists())
        self.assertEqual((self.config/'revision').read_text(),'0123456789abcdef')

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
