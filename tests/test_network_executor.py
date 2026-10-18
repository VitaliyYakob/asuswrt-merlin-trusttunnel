from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class ExecutorTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name);(self.path/'fakebin').mkdir();(self.path/'net').mkdir()
        # Copy, don't chmod symlink target in the user's checkout.
        content=(ROOT/'tests/mock_net.py').read_bytes()
        for name in ['fc','ip','iptables','ip6tables','iptables-restore','ip6tables-restore']:
            file=self.path/'fakebin'/name;file.write_bytes(content);file.chmod(0o755)
        proc=self.path/'sandbox/proc'
        (proc/'sys/kernel/random').mkdir(parents=True)
        (proc/'sys/kernel/random/boot_id').write_text('synthetic-boot-1')
        (proc/'uptime').write_text('1000.0 0.0\n')
        self.env=os.environ|{'TT_ROOT':str(self.path/'sandbox'),'TT_MOCK_NET':str(self.path/'net')}
    def execute(self,body,fail=''):
        script=f'''TT_BASE='{ROOT}/addon'
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/network.sh"
PATH='{self.path}/fakebin':"$PATH"
export PATH
tt_dirs || exit 91
cp '{ROOT}/examples/policy.example.json' "$TT_POLICY"
{body}
'''
        return subprocess.run(['sh','-c',script],env=self.env|{'TT_MOCK_FAIL':fail},text=True,capture_output=True)
    def state(self):return json.loads((self.path/'net/state.json').read_text())
    def test_guard_is_idempotent(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan guard "$TT_POLICY"')
        self.assertEqual(result.returncode,0,result.stderr)
        state=self.state();self.assertEqual(len(state['rules']),1)
        self.assertEqual(state['chains']['iptables:filter:FORWARD'].count(['-j','TTM4_FWD']),1)
        self.assertEqual(set(state['routes']),{'871:32760'})
    def test_pause_plan_keeps_blackhole_and_guards(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan up "$TT_POLICY" && tt_run_plan down "$TT_POLICY"')
        self.assertEqual(result.returncode,0,result.stderr)
        state=self.state();self.assertEqual(set(state['routes']),{'871:32760'})
        self.assertIn('iptables:filter:TTM4_FWD',state['chains'])
        self.assertEqual(len(state['rules']),1)
    def test_disarm_cleans_only_owned_objects(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan up "$TT_POLICY" && tt_disarm')
        self.assertEqual(result.returncode,0,result.stderr)
        state=self.state();self.assertEqual(state['rules'],[]);self.assertEqual(state['routes'],{})
        self.assertFalse(any('TTM' in x for x in state['chains']))
        self.assertFalse((self.path/'sandbox/tmp/trusttunnel/resources-owned').exists())
    def test_guard_failure_aborts_before_ip_rules(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY"',fail='ip6tables-restore')
        self.assertNotEqual(result.returncode,0)
        state=self.state();self.assertEqual(state['rules'],[]);self.assertEqual(state['routes'],{})
        self.assertTrue((self.path/'sandbox/tmp/trusttunnel/resources-owned').exists())
    def test_existing_resources_refused(self):
        result=self.execute('ip -4 rule add pref 17100 from 10.0.0.1/32 iif br0 lookup 100; tt_claim_resources')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.state()['rules'],[['17100','10.0.0.1/32','br0','100']])
        self.assertFalse((self.path/'sandbox/tmp/trusttunnel/resources-owned').exists())
    def test_existing_routing_table_refused(self):
        result=self.execute('ip -4 route replace default dev eth0 table 871 metric 100; tt_claim_resources')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('871:100',self.state()['routes'])
    def test_reserved_priority_conflict_not_deleted(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && ip -4 rule add pref 17100 from 10.0.0.1/32 iif br0 lookup 100 && tt_run_plan guard "$TT_POLICY"')
        self.assertNotEqual(result.returncode,0)
        self.assertIn(['17100','10.0.0.1/32','br0','100'],self.state()['rules'])
    def test_refresh_repositions_guard_before_foreign_accept(self):
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && iptables -t filter -I FORWARD 1 -j ACCEPT && tt_run_plan guard "$TT_POLICY"')
        self.assertEqual(result.returncode,0,result.stderr)
        chain=self.state()['chains']['iptables:filter:FORWARD']
        self.assertEqual(chain[0],['-j','TTM4_FWD'])
        self.assertIn(['-j','ACCEPT'],chain)
    def test_live_process_reconciles_missing_tunnel_route(self):
        result=self.execute('''tt_claim_resources && tt_run_plan guard "$TT_POLICY" || exit 1
. "$TT_BASE/lib/service.sh"
tt_pid_matches() { return 0; }
tt_rpf_loose() { return 0; }
ip() { if [ "$1" = link ]; then return 0; else command ip "$@"; fi; }
tt_spawn''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('871:10',self.state()['routes'])
    def test_flow_flush_is_scoped_to_selected_bridge_and_members(self):
        members=self.path/'sandbox/sys/class/net/br1/brif'
        members.mkdir(parents=True)
        for name in ('wl0.1','eth1.501'): (members/name).mkdir()
        (self.path/'sandbox/sys/class/net/br0/bridge').mkdir(parents=True)
        result=self.execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY"')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in (self.path/'net/calls.jsonl').read_text().splitlines()]
        fc=[c['argv'] for c in calls if c['program']=='fc']
        self.assertEqual(fc,[['flush','--if','br1'],['flush','--if','eth1.501'],['flush','--if','wl0.1']])
        rules=self.state()['chains']['iptables:filter:TTM4_FWD']
        self.assertEqual(rules[:2],[['-i','br1','-s','192.168.50.0/24','-j','SKIPLOG'],
                                   ['-o','br1','-d','192.168.50.0/24','-j','SKIPLOG']])
        self.assertTrue(all('br0' not in rule for rule in rules))
        last_restore=max(i for i,c in enumerate(calls) if c['program'].endswith('-restore'))
        first_fc=next(i for i,c in enumerate(calls) if c['program']=='fc')
        self.assertGreater(first_fc,last_restore)

    def test_failed_flow_flush_retains_guards_and_reports_fixed_error(self):
        result=self.execute('''tt_claim_resources && tt_run_plan guard "$TT_POLICY"
result=$?; printf '%s' "$TT_FAILURE_CODE"; exit "$result"''',fail='fc flush')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'offload_flush_failed')
        state=self.state()
        self.assertIn('iptables:filter:TTM4_FWD',state['chains'])
        self.assertEqual(set(state['routes']),{'871:32760'})
        self.assertEqual(len(state['rules']),1)
        self.assertTrue((self.path/'sandbox/tmp/trusttunnel/resources-owned').exists())

    def test_invalid_plan_not_silently_accepted(self):
        result=self.execute('tt_run_plan INVALID "$TT_POLICY"')
        self.assertNotEqual(result.returncode,0)

if __name__=='__main__':unittest.main()
