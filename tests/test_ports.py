"""Port-policy regressions; mocked commands do not prove real Ethernet forwarding."""
import json, unittest
from pathlib import Path
import test_network_executor as net
ROOT=Path(__file__).resolve().parents[1]

class PortTests(unittest.TestCase):
    execute=net.ExecutorTests.execute
    state=net.ExecutorTests.state
    def setUp(self):
        net.ExecutorTests.setUp(self)
        file=self.path/'fakebin/ebtables';file.write_bytes((ROOT/'tests/mock_ebtables.py').read_bytes());file.chmod(0o755)
        self.policy={'schema':4,'networks':[],'ports':[{'interface':'eth4','lan_if':'br0','identity':'a'*64}],
                     'local_access':[],'block_ipv6_bridge':True,'table':871,'priority':17100}
        self.file=self.path/'ports.json'; self.file.write_text(json.dumps(self.policy))
    def port_execute(self,body):
        # Mock all live commands explicitly after common.sh changes PATH.
        return self.execute(f'''cp '{self.file}' "$TT_POLICY"
tt_live() {{ return 0; }}
tt_ports_check() {{ return 0; }}
{body}''')
    def ethernet(self): return json.loads((self.path/'net/ethernet.json').read_text())
    def test_port_only_and_all_five_ports_validate(self):
        for count in (1,5):
            self.policy['ports']=[dict(interface=f'eth{i}',lan_if='br0',identity='a'*64) for i in range(1,count+1)]
            self.file.write_text(json.dumps(self.policy))
            r=self.port_execute('tt_validate policy "$TT_POLICY"');self.assertEqual(r.returncode,0,r.stderr)
        for field,value in [('interface','eth0'),('interface','eth4;reboot'),('lan_if','br1'),('identity','bad')]:
            self.policy['ports']=[dict(interface='eth4',lan_if='br0',identity='a'*64)];self.policy['ports'][0][field]=value
            self.file.write_text(json.dumps(self.policy));r=self.port_execute('tt_validate policy "$TT_POLICY"');self.assertNotEqual(r.returncode,0)
    def test_empty_selection_and_duplicate_ports_refused(self):
        for ports in ([],self.policy['ports']*2):
            self.policy['ports']=ports;self.file.write_text(json.dumps(self.policy))
            self.assertNotEqual(self.port_execute('tt_validate policy "$TT_POLICY"').returncode,0)
    def test_guard_owns_marked_rule_and_atomic_classifier_without_changing_main(self):
        r=self.port_execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan guard "$TT_POLICY"')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn(['17132','fwmark=0x10000000/0x10000000','br0','871'],self.state()['rules'])
        rules=self.state()['chains']['iptables:filter:TTM4_FWD']
        self.assertIn(['-m','mark','--mark','0x10000000/0x10000000','-j','REJECT'],rules)
        ethernet=self.ethernet()['broute'];self.assertEqual(ethernet['BROUTING'],[['-j','TTM_PORTS']]);self.assertEqual(len(ethernet['TTM_PORTS']),1)
        self.assertIn('eth4',ethernet['TTM_PORTS'][0]);self.assertTrue(all('br0' not in rule for rule in ethernet['TTM_PORTS']))
        self.assertEqual(set(self.state()['routes']),{'871:32760'})
        calls=[json.loads(l) for l in (self.path/'net/ethernet-calls.jsonl').read_text().splitlines()]
        self.assertTrue(all('--atomic-file' in a for a in calls if any(op in a for op in ('-F','-N','-A','-I','-X','-D'))))
    def test_pause_retains_classifier_disable_removes_only_owned_resources(self):
        r=self.port_execute('tt_claim_resources && tt_run_plan guard "$TT_POLICY" && tt_run_plan down "$TT_POLICY"')
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn('TTM_PORTS',self.ethernet()['broute'])
        r=self.port_execute('tt_disarm && rm -f "$TT_ENABLED" "$TT_PAUSED"');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.ethernet()['broute'],{'BROUTING':[]});self.assertEqual(self.state()['rules'],[])
        self.assertFalse((self.path/'sandbox/tmp/trusttunnel/ports-owned').exists())
    def test_unknown_ethernet_namespace_never_adopted(self):
        r=self.port_execute('ebtables -t broute -N TTM_PORTS; tt_ports_claim')
        self.assertNotEqual(r.returncode,0);self.assertIn('occupied',r.stderr)
        self.assertFalse((self.path/'sandbox/tmp/trusttunnel/ports-owned').exists())
    def test_classifier_failed_commit_leaves_live_rules_intact(self):
        r=self.port_execute('tt_ports_claim && tt_ports_classifier \'[{"interface":"eth4","mark":"0x10000000"}]\'')
        self.assertEqual(r.returncode,0,r.stderr);before=self.ethernet()
        r=self.port_execute('export TT_EB_FAIL=--atomic-commit; tt_ports_classifier \'[{"interface":"eth3","mark":"0x20000000"}]\'')
        self.assertNotEqual(r.returncode,0);self.assertEqual(self.ethernet(),before)
    def test_transaction_union_quarantines_removed_ports_until_confirm(self):
        r=self.port_execute('''mkdir "$TT_CONFIG/transaction"
cp "$TT_POLICY" "$TT_CONFIG/transaction/old-policy.json"
jq '.ports[0].interface="eth3"' "$TT_POLICY" >"$TT_CONFIG/transaction/new-policy.json"
tt_ports_transaction block && tt_ports_transaction trial''')
        self.assertEqual(r.returncode,0,r.stderr)
        rules=self.ethernet()['broute']['TTM_PORTS'];self.assertEqual(len(rules),2)
        self.assertTrue(any('eth4' in rule and '0x20000000' in rule for rule in rules))
        self.assertTrue(any('eth3' in rule and '0x10000000' in rule for rule in rules))
        r=self.port_execute('''cp "$TT_CONFIG/transaction/new-policy.json" "$TT_POLICY"; tt_ports_transaction remove''')
        self.assertEqual(r.returncode,0,r.stderr);rules=self.ethernet()['broute']['TTM_PORTS'];self.assertEqual(len(rules),1);self.assertIn('eth3',rules[0])
    def test_offline_inventory_and_live_classifier_refuse_host_network(self):
        r=self.execute('''ebtables() { echo HOST_CALL >&2; }; ip() { echo HOST_CALL >&2; }
tt_port_inventory; tt_ports_classifier '[]' ''')
        self.assertNotEqual(r.returncode,0);self.assertEqual(r.stdout.strip(),'[]');self.assertNotIn('HOST_CALL',r.stderr)
    def test_real_inventory_maps_labels_and_excludes_wan_iptv_lag(self):
        # Live inventory is filesystem/NVRAM-only with explicit fake getters.
        for name in ('eth1','eth2','eth3','eth4','eth5'):
            (self.path/'sandbox/sys/class/net/br0/brif'/name).mkdir(parents=True)
        r=self.execute('''TT_ROOT=
tt_nvram_get() { case "$1" in productid) echo RT-AX86U;; wans_dualwan) echo 'wan none';; switch_stb_x|lacp_enabled) echo 0;; wan0_ifname) echo eth5;; esac; }
tt_discover_networks() { printf '[{"lan_if":"br0","identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'; }
tt_port_inventory''')
        self.assertEqual(r.returncode,0,r.stderr);ports=json.loads(r.stdout)
        self.assertEqual([p['interface'] for p in ports],['eth4','eth3','eth2','eth1','eth5'])
        self.assertTrue(all(p['available'] for p in ports[:4]));self.assertFalse(ports[4]['available'])
    def test_unknown_model_has_no_guessed_ports(self):
        r=self.execute('''TT_ROOT=; tt_nvram_get() { echo unknown; }; tt_port_inventory''')
        self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout),[])
    def test_full_transaction_confirm_and_rollback_restore_port_policy(self):
        for action,expected in [('tt_transaction_confirm "$TT_OP_ID"','eth3'),('tt_transaction_rollback','eth4')]:
            with self.subTest(action=action):
                r=self.port_execute('''. "$TT_BASE/lib/service.sh"
. "$TT_BASE/lib/transaction.sh"
tt_preflight() { return 0; }; tt_rpf_loose() { return 0; }; tt_rpf_prune() { return 0; }
tt_spawn() { tt_run_plan up "$TT_RUNTIME_POLICY"; }; tt_stop_process() { return 0; }
cp "$TT_BASE/../examples/endpoint.example.json" "$TT_ENDPOINT"
tt_import policy "$TT_POLICY" || exit 89
: >"$TT_ENABLED"
tt_claim_resources && tt_run_plan guard "$TT_POLICY" || exit 90
jq '.ports[0].interface="eth3"' "$TT_POLICY" >"$TT_RUN/candidate.json"
TT_OP_ID=0123456789abcdef
tt_transaction_apply policy "$TT_RUN/candidate.json" && '''+action)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertFalse(any('TXN' in c for c in self.state()['chains']))
                rules=self.ethernet()['broute']['TTM_PORTS'];self.assertEqual(len(rules),1);self.assertIn(expected,rules[0]);self.assertIn('0x10000000',rules[0])
                r=self.port_execute('tt_disarm && rm -f "$TT_ENABLED" "$TT_PAUSED"');self.assertEqual(r.returncode,0,r.stderr)

    def test_concurrent_foreign_ethernet_edit_is_not_overwritten(self):
        r=self.port_execute('''tt_ports_claim && tt_ports_classifier '[{"interface":"eth4","mark":"0x10000000"}]' ''')
        self.assertEqual(r.returncode,0,r.stderr)
        r=self.port_execute('''export TT_EB_RACE=1; tt_ports_classifier '[{"interface":"eth2","mark":"0x10000000"}]' ''')
        self.assertNotEqual(r.returncode,0);self.assertIn('changed concurrently',r.stderr)
        table=self.ethernet()['broute'];self.assertIn(['-i','eth3','-j','ACCEPT'],table['BROUTING'])
        self.assertIn('eth4',table['TTM_PORTS'][0])
