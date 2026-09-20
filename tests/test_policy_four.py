import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import test_network_executor as net

ROOT=Path(__file__).resolve().parents[1]


class PolicyFourTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.policy={'schema':4,'networks':[{'lan_if':'br1','sources':['192.168.51.10/32'],'identity':'a'*64}],
                     'local_access':[{'lan_if':'br0','destination':'192.168.50.0/24','identity':'b'*64}],
                     'block_ipv6_bridge':True,'table':871,'priority':17100}

    def validate(self):
        file=self.path/'policy.json'; file.write_text(json.dumps(self.policy))
        return subprocess.run(['sh',str(ROOT/'addon/trusttunnel.sh'),'validate','policy',str(file)],capture_output=True,text=True)

    def test_topology_identity_required_and_local_destinations_bounded(self):
        self.assertEqual(self.validate().returncode,0)
        del self.policy['networks'][0]['identity']
        self.assertNotEqual(self.validate().returncode,0)
        self.policy['networks'][0]['identity']='a'*64
        for destination in ('0.0.0.0/0','8.8.8.8/32','192.168.50.1/24','192.168.50.0/24;reboot'):
            self.policy['local_access'][0]['destination']=destination
            self.assertNotEqual(self.validate().returncode,0)

    def test_local_access_returns_to_merlin_filters_without_main_route_edits(self):
        self.assertEqual(self.validate().returncode,0)
        result=subprocess.run(['sh',str(ROOT/'addon/trusttunnel.sh'),'plan','guard',str(self.path/'policy.json')],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        plan=json.loads(result.stdout)
        lines='\n'.join(item.get('stdin','') for item in plan)
        self.assertIn('-d 192.168.50.0/24 -o br0 -j RETURN',lines)
        self.assertNotIn('-d 192.168.50.0/24 -o br0 -j ACCEPT',lines)
        routes=[item['argv'] for item in plan if item['op']=='command']
        self.assertTrue(all('871' in route and 'main' not in route for route in routes))
        self.assertIn('-i br1 -j REJECT',lines)  # IPv6 remains bridge-wide.

    def test_changed_topology_refuses_preflight(self):
        self.validate()
        script='''TT_BASE="$TT_PROJECT/addon"
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/service.sh"
TT_POLICY="$TT_FIXTURE/policy.json"
tt_discover_networks() { printf '[]'; }
tt_check_interfaces'''
        result=subprocess.run(['sh','-c',script],env=os.environ|{'TT_PROJECT':str(ROOT),'TT_ROOT':str(self.path),'TT_FIXTURE':str(self.path)},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('topology changed',result.stderr)


class LocalRoutesExecutor(unittest.TestCase):
    setUp=net.ExecutorTests.setUp
    execute=net.ExecutorTests.execute
    state=net.ExecutorTests.state

    def test_multiple_local_routes_reconcile_and_cleanup(self):
        result=self.execute('''jq '.schema=4 | .networks=[{lan_if:.lan_if,sources:.sources,identity:("a"*64)}] |
del(.lan_if,.sources,.dns_ipv4) | .local_access=[{lan_if:"br0",destination:"192.168.1.0/24",identity:("b"*64)},
{lan_if:"br2",destination:"192.168.2.0/24",identity:("c"*64)}]' "$TT_POLICY" >"$TT_RUN/new.json"
tt_import policy "$TT_RUN/new.json" && tt_claim_resources && tt_run_plan guard "$TT_POLICY" &&
tt_run_plan guard "$TT_POLICY" && tt_disarm''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.state()['routes'],{})
        self.assertEqual(self.state()['rules'],[])
