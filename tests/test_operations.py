import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class OperationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)

    def run_shell(self,body):
        return subprocess.run(['busybox','ash','-c','''TT_BASE="$TT_PROJECT/addon"
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/transfer.sh"
. "$TT_BASE/lib/diagnostics.sh"
tt_dirs || exit 90
'''+body],env=os.environ|{'TT_ROOT':str(self.path),'TT_PROJECT':str(ROOT)},capture_output=True,text=True)

    def test_runtime_operation_replay_does_not_execute_twice(self):
        result=self.run_shell('''tt_start() { echo started >>"$TT_RUN/calls"; }
tt_wire_dispatch ttm_do_0123456789abcdef_start && tt_wire_dispatch ttm_do_0123456789abcdef_start''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.path/'tmp/trusttunnel/calls').read_text(),'started\n')

    def test_failed_runtime_id_still_cannot_be_replayed(self):
        result=self.run_shell('''tt_start() { echo started >>"$TT_RUN/calls"; return 1; }
tt_wire_dispatch ttm_do_0123456789abcdef_start
tt_wire_dispatch ttm_do_0123456789abcdef_start''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.path/'tmp/trusttunnel/calls').read_text(),'started\n')
        operation=json.loads((self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').read_text())
        self.assertEqual(operation['state'],'failed')

    def test_diagnostics_never_query_live_network_with_tt_root(self):
        result=self.run_shell('''ip() { echo HOST_CALL >&2; return 99; }
iptables() { echo HOST_CALL >&2; return 99; }
nvram() { echo HOST_CALL >&2; return 99; }
cp "$TT_BASE/../examples/endpoint.example.json" "$TT_ENDPOINT"
tt_diagnostics''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('HOST_CALL',result.stderr)
        report=json.loads(result.stdout)
        self.assertFalse(report['packet_path_verified'])
        self.assertNotIn('password',result.stdout)
        self.assertNotIn('username',result.stdout)
        self.assertNotIn('hostname',result.stdout)

    def test_pending_transaction_refuses_runtime_control(self):
        result=self.run_shell('''mkdir "$TT_CONFIG/transaction"; printf '{}' >"$TT_CONFIG/transaction/manifest.json"
tt_start() { echo UNEXPECTED >&2; return 0; }
tt_wire_dispatch ttm_do_0123456789abcdef_start''')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('UNEXPECTED',result.stderr)
        op=json.loads((self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').read_text())
        self.assertEqual(op['code'],'transaction_pending')

    def test_traffic_check_reports_running_requirement(self):
        result=self.run_shell('''tt_verify_traffic() { TT_FAILURE_CODE=check_not_running; return 1; }
tt_wire_dispatch ttm_do_0123456789abcdef_verify_traffic''')
        self.assertNotEqual(result.returncode,0)
        op=json.loads((self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').read_text())
        self.assertEqual(op['action'],'verify_traffic')
        self.assertEqual(op['code'],'check_not_running')

    def test_dhcp_inventory_preserves_names_as_data_and_skips_bad_ip(self):
        leases=self.path/'var/lib/misc'; leases.mkdir(parents=True)
        (leases/'dnsmasq.leases').write_text('0 aa:bb:cc:dd:ee:ff 192.168.1.10 <script> *\n0 aa:bb:cc:dd:ee:00 999.2.3.4 nope *\n')
        result=self.run_shell('tt_client_inventory')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([c['name'] for c in json.loads(result.stdout)],['<script>'])

    def test_dhcp_clients_are_joined_to_actual_wireless_mac_associations(self):
        leases=self.path/'var/lib/misc'; leases.mkdir(parents=True)
        (leases/'dnsmasq.leases').write_text('0 AA:BB:CC:DD:EE:01 192.168.1.10 Home-device *\n0 aa:bb:cc:dd:ee:02 192.168.1.20 Legacy-device *\n0 aa:bb:cc:dd:ee:03 192.168.1.30 Unassociated *\n')
        result=self.run_shell('''tt_wifi_associations() { printf '%s' '[{"mac":"aa:bb:cc:dd:ee:01","lan_if":"br0","ssid":"Home","ifname":"eth6","nvif":"wl0"},{"mac":"aa:bb:cc:dd:ee:02","lan_if":"br0","ssid":"Legacy","ifname":"wl0.2","nvif":"wl0.2"}]'; }
tt_client_inventory''')
        self.assertEqual(result.returncode,0,result.stderr)
        clients=json.loads(result.stdout)
        self.assertEqual([c['wireless'][0]['ssid'] if c['wireless'] else None for c in clients],['Home','Legacy',None])
        self.assertNotIn('mac',clients[0]['wireless'][0])
