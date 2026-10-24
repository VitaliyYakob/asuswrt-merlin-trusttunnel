"""Traffic observations are mocked, never a hardware leak test."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class TrafficObservationTests(unittest.TestCase):
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
. "$TT_BASE/lib/traffic-observation.sh"
tt_dirs || exit 90
date() { printf '1800000000\n'; }
'''+body],capture_output=True,text=True,env=os.environ|{'TT_ROOT':str(self.path),'TT_BASE':str(ROOT/'addon')})

    def test_sandbox_refuses_live_queries(self):
        r=self.shell('ip() { echo HOST_CALL >&2; }; iptables() { echo HOST_CALL >&2; }; tt_tunnel_addresses; tt_observe_traffic; tt_traffic_baseline')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('HOST_CALL',r.stdout+r.stderr)
        self.assertEqual(r.stdout.strip(),'[]')

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

class AutomaticTrafficTests(unittest.TestCase):
    shell=TrafficObservationTests.shell
    def auto(self,body=''):
        # No host networking: all collector dependencies are explicitly replaced.
        return self.shell('''TT_ROOT=
tt_pid_matches() { return 0; }
tt_check_guard_rules() { return 0; }
tt_uptime() { cat "$TT_PROC/test-up"; }
date() { cat "$TT_PROC/test-now"; }
tt_packet_snapshot() { cat "$TT_PROC/test-packets"; }
: >"$TT_ENABLED"; printf 42 >"$TT_RUN/client.start"
'''+body)
    def setUp(self):
        TrafficObservationTests.setUp(self)
        self.values(1000,1800000000,1,2)
    def values(self,up,now,sent,received):
        for key,value in [('up',str(up)),('now',str(now)),('packets',json.dumps(dict(sent=sent,received=received)))]:
            (self.path/'proc'/('test-'+key)).write_text(value)
    def test_initial_sample_then_fresh_bidirectional_observation(self):
        r=self.auto('tt_observe_traffic && tt_observation_status');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['state'],'sampling')
        self.values(1060,1800000060,9,12)
        r=self.auto('tt_observe_traffic && tt_observation_status');self.assertEqual(r.returncode,0,r.stderr)
        report=json.loads(r.stdout);self.assertEqual(report['state'],'traffic_observed');self.assertEqual(report['checked_at'],1800000060)
        self.assertEqual((report['sent_packets'],report['received_packets'],report['interval_seconds']),(8,10,60))
        self.assertFalse(report['leak_test_verified'])
        self.assertFalse((self.config/'traffic-check.json').exists())
    def test_calendar_jump_restarts_sampling_and_never_reports_future_check(self):
        self.auto('tt_observe_traffic')
        self.values(1020,1790000000,9,12)
        r=self.auto('tt_observe_traffic && tt_observation_status');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['checked_at'],1790000000)
        self.assertEqual(json.loads(r.stdout)['state'],'sampling')
    def test_stale_or_different_generation_is_not_current(self):
        self.auto('tt_observe_traffic')
        self.values(1200,1800000200,9,12)
        self.assertIsNone(json.loads(self.auto('tt_observation_status').stdout))
        self.values(1000,1800000000,9,12)
        self.assertIsNone(json.loads(self.auto('printf 43 >"$TT_RUN/client.start"; tt_observation_status').stdout))
    def test_corrupted_sample_recovers_without_writing_flash(self):
        for content in ('{','{}','[]','null','{}\n{}'):
            self.auto('true');(self.run/'traffic-sample.json').write_text(content)
            r=self.auto('tt_observe_traffic && tt_observation_status');self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(json.loads(r.stdout)['state'],'sampling')

    def test_firewall_reset_rebaselines_without_faking_observation_date(self):
        self.auto('tt_observe_traffic')
        self.values(1060,1800000060,9,12)
        first=json.loads(self.auto('tt_observe_traffic; tt_observation_status').stdout)
        self.values(1061,1800000061,0,0)
        after=json.loads(self.auto('tt_traffic_baseline; tt_observe_traffic; tt_observation_status').stdout)
        self.assertEqual(first,after)
        self.values(1120,1800000120,5,8)
        report=json.loads(self.auto('tt_observe_traffic; tt_observation_status').stdout)
        self.assertEqual(report['state'],'traffic_observed')
        self.assertEqual((report['sent_packets'],report['received_packets'],report['interval_seconds']),(5,8,59))

    def test_idle_one_direction_missing_rules_and_counter_reset(self):
        for sent,received,guard,expected in [(1,2,True,'idle'),(9,2,True,'idle'),(9,12,False,'incomplete'),(0,0,True,'counters_reset')]:
            with self.subTest(state=expected):
                self.values(1000,1800000000,1,2)
                self.auto('rm -f "$TT_RUN/traffic-sample.json" "$TT_RUN/traffic-observation.json"; tt_observe_traffic')
                self.values(1060,1800000060,sent,received)
                report=json.loads(self.auto(('tt_check_guard_rules() { return 1; }; ' if not guard else '')+'tt_observe_traffic; tt_observation_status').stdout)
                self.assertEqual(report['state'],expected)
                self.assertFalse(report['leak_test_verified'])

    def test_observation_invalidates_after_pause_revision_or_boot_change(self):
        self.auto('tt_observe_traffic')
        for change in [': >"$TT_PAUSED"','printf changed >"$TT_CONFIG/revision"','printf next-boot >"$TT_PROC/sys/kernel/random/boot_id"']:
            with self.subTest(change=change):
                report=self.auto(change+'; tt_observation_status')
                self.assertEqual(report.returncode,0,report.stderr)
                self.assertIsNone(json.loads(report.stdout))
                # Reset context independently; the next case cannot pass just
                # because the preceding case already invalidated the sample.
                self.auto('rm -f "$TT_PAUSED" "$TT_CONFIG/revision"; printf fixture-boot >"$TT_PROC/sys/kernel/random/boot_id"')

    def test_legacy_history_is_not_read_or_migrated_by_publication(self):
        self.auto('true')
        (self.run/'traffic-check.json').write_text('legacy-runtime-record')
        (self.config/'traffic-check.json').write_text('legacy-private-record')
        result=self.auto(''' . "$TT_BASE/lib/service.sh"
tt_status() { printf '{}\\n'; }
tt_publish_status''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.run/'traffic-check.json').read_text(),'legacy-runtime-record')
        self.assertEqual((self.config/'traffic-check.json').read_text(),'legacy-private-record')
        self.assertFalse((self.run/'status.json').read_text().find('legacy')>=0)
