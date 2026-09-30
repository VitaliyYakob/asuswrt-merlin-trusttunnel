import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class StartupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
    def execute(self, body):
        return subprocess.run(['busybox','ash','-c','''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/service.sh"
. "$TT_BASE/lib/transfer.sh"
tt_dirs || exit 99
'''+body],env=os.environ|{'TT_ROOT':str(self.path),'TT_BASE':str(ROOT/'addon')},capture_output=True,text=True)
    def test_offline_readiness_does_not_inspect_host_or_load_modules(self):
        r=self.execute('''fc() { echo HOST_CALL >&2; return 99; }
nvram() { echo HOST_CALL >&2; return 99; }
modprobe() { echo HOST_CALL >&2; return 99; }
tt_start_readiness''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('HOST_CALL',r.stderr)
        self.assertEqual(json.loads(r.stdout)['blockers'],['endpoint_missing','policy_missing','offload_unavailable'])
    def test_sandbox_refuses_tun_loading(self):
        r=self.execute('modprobe() { echo HOST_CALL >&2; }; tt_ensure_tun')
        self.assertNotEqual(r.returncode,0)
        self.assertNotIn('HOST_CALL',r.stderr)
    def test_actual_hnd_state_overrides_legacy_ctf_flag(self):
        r=self.execute('''fc() { printf 'HW Acceleration <Enabled>\nFlow Learning Enabled : Max<1>\n'; }
nvram() { echo 1; }
TT_ROOT=
tt_acceleration_state''')
        self.assertEqual(r.stdout.strip(),'enabled')
    def test_hnd_requires_both_engines_disabled(self):
        for status,expected in [
            ('HW Acceleration <Disabled>\nFlow Learning Disabled','disabled'),
            ('HW Acceleration <Disabled>\nFlow Learning Enabled','enabled'),
            ('HW Acceleration <Enabled>\nFlow Learning Disabled','enabled'),
            ('HW Acceleration <Disabled>','unknown'),
            ('HW Acceleration <Disabled>\nFlow Ucast Learning Disabled\nFlow Mcast Learning Enabled','enabled'),
            ('unrecognized firmware output','unknown')]:
            with self.subTest(status=status):
                (self.path/'fc-status').write_text(status)
                r=self.execute('''fixture=$TT_ROOT/fc-status
fc() { cat "$fixture"; }
TT_ROOT=
tt_acceleration_state''')
                self.assertEqual(r.stdout.strip(),expected,r.stderr)
    def test_failed_hnd_query_is_unknown(self):
        r=self.execute('fc() { return 1; }; TT_ROOT=; tt_acceleration_state')
        self.assertEqual(r.stdout.strip(),'unknown')
    def test_missing_policy_reports_actionable_code_before_network_access(self):
        # Older BusyBox ash rejects hyphens in function names. Use executable
        # mocks, including the restore tools, and prepend them after common.sh.
        fakebin=self.path/'fakebin'; fakebin.mkdir()
        for name in ('ip','iptables','ip6tables','iptables-restore','ip6tables-restore','modprobe'):
            mock=fakebin/name
            mock.write_text('#!/bin/sh\nprintf "UNEXPECTED\\n" >&2\nexit 99\n')
            mock.chmod(0o755)
        r=self.execute('''tt_live() { return 0; }
PATH="$TT_ROOT/fakebin:$PATH"
export PATH
cp "$TT_BASE/../examples/endpoint.example.json" "$TT_ENDPOINT"
tt_wire_dispatch ttm_do_0123456789abcdef_start''')
        self.assertNotEqual(r.returncode,0)
        self.assertNotIn('UNEXPECTED',r.stderr)
        operation=self.path/'tmp/trusttunnel/operations/0123456789abcdef.json'
        self.assertTrue(operation.is_file(),r.stderr)
        op=json.loads(operation.read_text())
        self.assertEqual(op['code'],'policy_missing')
        self.assertFalse((self.path/'jffs/addons/trusttunnel/config/enabled').exists())
    def test_arbitrary_failure_text_cannot_be_published_as_code(self):
        r=self.execute('''tt_start() { TT_FAILURE_CODE='SYNTHETIC_SECRET'; return 1; }
tt_wire_dispatch ttm_do_0123456789abcdef_start''')
        self.assertNotEqual(r.returncode,0)
        raw=(self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').read_text()
        self.assertNotIn('SYNTHETIC_SECRET',raw)
        self.assertEqual(json.loads(raw)['code'],'action_failed')

    def test_start_loads_only_tun_and_rechecks_device(self):
        r=self.execute("""tt_tun_available() { [ "$loaded" = yes ]; }
modprobe() { [ "$1" = tun ] && [ "$#" = 1 ] || return 99; loaded=yes; }
TT_ROOT=
tt_ensure_tun && tt_ensure_tun""")
        self.assertEqual(r.returncode,0,r.stderr)
    def test_failed_module_load_produces_tun_error(self):
        r=self.execute("""tt_tun_available() { return 1; }
modprobe() { return 1; }
TT_ROOT=
tt_ensure_tun; result=$?; printf '%s' "$TT_FAILURE_CODE"; exit "$result"
""")
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(r.stdout,'tun_unavailable')

    def test_selective_offload_requires_both_protocol_targets(self):
        net=self.path/'proc/net'; net.mkdir(parents=True)
        for v4,v6,expected in [('SKIPLOG','SKIPLOG',0),('ACCEPT','SKIPLOG',1),('SKIPLOG','ACCEPT',1)]:
            with self.subTest(v4=v4,v6=v6):
                (net/'ip_tables_targets').write_text(v4+'\n')
                (net/'ip6_tables_targets').write_text(v6+'\n')
                r=self.execute('fc() { return 99; }; TT_ROOT=; tt_selective_offload_supported')
                self.assertEqual(r.returncode,expected,r.stderr)

    def test_refresh_restores_guards_before_failed_client_recovery(self):
        r=self.execute('''touch "$TT_ENABLED"
tt_live() { return 0; }; tt_validate() { return 0; }
tt_claim_resources() { return 0; }; tt_rpf_loose() { return 0; }
tt_run_plan() { printf 'guard\n' >>"$TT_RUN/effects"; }
tt_update_recover() { printf 'recover\n' >>"$TT_RUN/effects"; return 1; }
tt_retry_client() { printf 'spawn\n' >>"$TT_RUN/effects"; }
tt_refresh''')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.path/'tmp/trusttunnel/effects').read_text(),'guard\nrecover\n')
