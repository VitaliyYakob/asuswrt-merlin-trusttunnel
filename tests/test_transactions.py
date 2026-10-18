"""Filesystem + command recorder tests; never a router or packet-flow test."""
import json
from pathlib import Path
import unittest
import test_network_executor as net


class TransactionTests(unittest.TestCase):
    setUp = net.ExecutorTests.setUp
    execute = net.ExecutorTests.execute
    state = net.ExecutorTests.state

    def run_case(self, body):
        return self.execute('''
. "$TT_BASE/lib/service.sh"
. "$TT_BASE/lib/transaction.sh"
tt_live() { return 0; }
tt_preflight() { return 0; }
tt_rpf_loose() { return 0; }
tt_spawn() { tt_run_plan up "$TT_RUNTIME_POLICY"; }
tt_stop_process() { return 0; }
cp "$TT_BASE/../examples/endpoint.example.json" "$TT_ENDPOINT"
tt_import policy "$TT_POLICY" || exit 89
: >"$TT_ENABLED"
tt_claim_resources && tt_run_plan guard "$TT_POLICY" || exit 90
jq '.networks=[{lan_if:"br2",sources:["192.168.52.0/24"]}] | .schema=3 | del(.lan_if,.sources,.dns_ipv4)' "$TT_POLICY" >"$TT_RUN/candidate.json"
TT_OP_ID=0123456789abcdef
''' + body)

    def test_trial_requires_confirmation_and_covers_removed_network(self):
        r = self.run_case('tt_transaction_apply policy "$TT_RUN/candidate.json"')
        self.assertEqual(r.returncode, 0, r.stderr)
        state = self.state()
        chain = state['chains']['iptables:filter:TTM4_TXN']
        self.assertIn(['-i','br2','-s','192.168.52.0/24','-j','RETURN'], chain)
        self.assertTrue(any(rule[-1]=='REJECT' and rule[1]=='br1' for rule in chain))
        manifest = self.path/'sandbox/jffs/addons/trusttunnel/config/transaction/manifest.json'
        self.assertEqual(json.loads(manifest.read_text())['phase'], 'trial')

    def test_confirmation_removes_only_quarantine(self):
        r = self.run_case('tt_transaction_apply policy "$TT_RUN/candidate.json" && tt_transaction_confirm "$TT_OP_ID"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any('TXN' in key for key in self.state()['chains']))
        self.assertIn('iptables:filter:TTM4_FWD', self.state()['chains'])
        self.assertEqual(self.state()['rules'][0][2], 'br2')

    def test_rollback_restores_old_policy_and_enabled_intent(self):
        r = self.run_case('tt_transaction_apply policy "$TT_RUN/candidate.json" && tt_transaction_rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()['rules'][0][2], 'br1')
        self.assertFalse(any('TXN' in key for key in self.state()['chains']))
        self.assertTrue((self.path/'sandbox/jffs/addons/trusttunnel/config/enabled').exists())

    def test_expiry_reconciles_to_old_policy(self):
        r = self.run_case('''tt_transaction_apply policy "$TT_RUN/candidate.json" || exit 1
jq '.timer.deadline=0' "$TT_CONFIG/transaction/manifest.json" >"$TT_RUN/expired"
mv "$TT_RUN/expired" "$TT_CONFIG/transaction/manifest.json"
tt_transaction_reconcile''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()['rules'][0][2], 'br1')

    def test_failed_client_start_retains_quarantine_on_failed_recovery(self):
        r = self.run_case('tt_spawn() { return 1; }; tt_transaction_apply policy "$TT_RUN/candidate.json"')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('iptables:filter:TTM4_TXN', self.state()['chains'])
        self.assertTrue((self.path/'sandbox/jffs/addons/trusttunnel/config/transaction/manifest.json').exists())

    def test_foreign_transaction_chain_is_never_claimed(self):
        r = self.run_case('iptables -t filter -N TTM4_TXN; iptables -t filter -A TTM4_TXN -j ACCEPT; tt_transaction_apply policy "$TT_RUN/candidate.json"')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.state()['chains']['iptables:filter:TTM4_TXN'], [['-j','ACCEPT']])

    def test_reboot_recovery_refuses_unknown_runtime_objects(self):
        r = self.run_case('''tt_transaction_apply policy "$TT_RUN/candidate.json" || exit 1
rm "$TT_RUN/transaction-owned" "$TT_OWNED" "$TT_RUNTIME_POLICY"
tt_transaction_rollback''')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('already occupied', r.stderr)
        self.assertEqual(self.state()['rules'][0][2], 'br2')

    def test_endpoint_transaction_restores_private_connection(self):
        r=self.run_case('''cp "$TT_ENDPOINT" "$TT_RUN/original-endpoint.json"
jq '.password="synthetic-new-secret"' "$TT_ENDPOINT" >"$TT_RUN/new-endpoint.json"
tt_stop_process() { echo stopped >>"$TT_RUN/stops"; return 0; }
tt_transaction_apply endpoint "$TT_RUN/new-endpoint.json" &&
jq -e '.password=="synthetic-new-secret"' "$TT_ENDPOINT" >/dev/null &&
tt_transaction_rollback &&
jq -S . "$TT_RUN/original-endpoint.json" >"$TT_RUN/expected-endpoint.json" &&
cmp -s "$TT_ENDPOINT" "$TT_RUN/expected-endpoint.json"''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.path/'sandbox/tmp/trusttunnel/stops').read_text(),'stopped\nstopped\n')

    def test_paused_policy_change_and_recovery_do_not_start_client(self):
        r=self.run_case(''': >"$TT_PAUSED"
tt_spawn() { echo UNEXPECTED >&2; return 99; }
tt_transaction_apply policy "$TT_RUN/candidate.json" && tt_transaction_rollback''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('UNEXPECTED',r.stderr)
        self.assertNotIn('871:10',self.state()['routes'])
        self.assertTrue((self.path/'sandbox/jffs/addons/trusttunnel/config/paused').exists())

    def test_recovery_after_reboot_with_empty_namespace_restores_previous_policy(self):
        r=self.run_case('''tt_transaction_apply policy "$TT_RUN/candidate.json" || exit 1
rm "$TT_RUN/transaction-owned" "$TT_OWNED" "$TT_RUNTIME_POLICY"
printf '{"chains":{},"rules":[],"routes":{}}' >"$TT_MOCK_NET/state.json"
tt_transaction_rollback''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.state()['rules'][0][2],'br1')
        self.assertFalse(any('TXN' in chain for chain in self.state()['chains']))

    def test_confirmation_restores_rpf_for_bridge_removed_from_policy(self):
        r=self.run_case('''. "$TT_BASE/lib/network.sh"
for interface in br1 br2 tt0; do
    mkdir -p "$TT_PROC/sys/net/ipv4/conf/$interface"
    printf '1\n' >"$TT_PROC/sys/net/ipv4/conf/$interface/rp_filter"
done
tt_rpf_loose && tt_transaction_apply policy "$TT_RUN/candidate.json" && tt_transaction_confirm "$TT_OP_ID"''')
        self.assertEqual(r.returncode,0,r.stderr)
        base=self.path/'sandbox/proc/sys/net/ipv4/conf'
        self.assertEqual((base/'br1/rp_filter').read_text().strip(),'1')
        self.assertEqual((base/'br2/rp_filter').read_text().strip(),'2')
