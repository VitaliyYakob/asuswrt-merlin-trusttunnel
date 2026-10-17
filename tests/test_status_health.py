"""Read-only collection must not freeze status or retain the controller lock."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StatusHealthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.fakebin = self.path / 'fakebin'; self.fakebin.mkdir()
        self.env = os.environ | {'TT_ROOT': str(self.path), 'TT_BASE': str(ROOT / 'addon'),
                                 'TT_TEST_TIMEOUT': shutil.which('timeout') or 'timeout',
                                 'TT_TEST_DIR': str(self.path)}

    def execute(self, body):
        return subprocess.run(['busybox', 'ash', '-c', '''
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/service.sh"
. "$TT_BASE/lib/transfer.sh"
tt_dirs || exit 99
PATH="$TT_TEST_DIR/fakebin:$PATH"
export PATH
''' + body], env=self.env, capture_output=True, text=True, timeout=8)

    def mock(self, name, body):
        file = self.fakebin / name
        file.write_text('#!/bin/sh\n' + body); file.chmod(0o755)

    def assert_lock_free(self):
        with (self.path / 'tmp/trusttunnel/control.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_hung_nvram_is_killed_partial_output_discarded_and_circuit_opens(self):
        self.mock('nvram', '''printf 'call\n' >>"$TT_TEST_DIR/calls"
[ ! -e /dev/fd/9 ] || exit 98
printf 'SYNTHETIC_PARTIAL_SSID'
trap '' TERM
while :; do :; done
''')
        start = time.monotonic()
        result = self.execute('''timeout() {
    [ "$1" = -k ] && [ "$2" = 1 ] && [ "$3" = 2 ] || return 98
    shift 3; "$TT_TEST_TIMEOUT" -k 0.1 1 "$@"
}
tt_lock || exit 90
TT_ROOT=
tt_nvram_get wl1_bss_enabled; first=$?
tt_nvram_get productid; second=$?
[ "$first" -ne 0 ] && [ "$second" -ne 0 ]
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual((self.path / 'calls').read_text(), 'call\n')
        self.assertLess(time.monotonic() - start, 4)
        marker = self.path / 'tmp/trusttunnel/nvram-failed'
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assert_lock_free()

    def test_nvram_success_preserves_newlines_and_closes_lock_fd(self):
        self.mock('nvram', '[ ! -e /dev/fd/9 ] || exit 98\nprintf "Demo\\n\\n"\n')
        result = self.execute('tt_lock || exit 90; TT_ROOT=; tt_nvram_get wl0_ssid')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'Demo\n\n')
        self.assertFalse((self.path / 'tmp/trusttunnel/nvram-failed').exists())
        self.assert_lock_free()

    def test_offline_nvram_never_executes_firmware_command(self):
        self.mock('nvram', 'touch "$TT_TEST_DIR/unexpected"\n')
        result = self.execute('tt_nvram_get rc_support')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / 'unexpected').exists())

    def test_circuit_retries_after_expiry(self):
        self.mock('nvram', 'printf "ready\\n"\n')
        result = self.execute('''printf '1\n' >"$TT_RUN/nvram-failed"
TT_ROOT=
tt_nvram_get productid''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'ready\n')
        self.assertFalse((self.path / 'tmp/trusttunnel/nvram-failed').exists())

    def test_readonly_worker_has_deadline_and_no_lock_descriptor(self):
        worker = self.path / 'trusttunnel.sh'
        worker.write_text('''#!/bin/sh
[ "$1" = status-details ] && [ ! -e /dev/fd/9 ] || exit 98
printf 'started\n' >"$TT_TEST_DIR/worker-started"
trap '' TERM
printf 'INCOMPLETE_JSON'
while :; do :; done
'''); worker.chmod(0o755)
        result = self.execute('''timeout() {
    [ "$1" = -k ] && [ "$2" = 1 ] && [ "$3" = 15 ] || return 98
    shift 3; "$TT_TEST_TIMEOUT" -k 0.1 1 "$@"
}
tt_lock || exit 90
TT_BASE=$TT_TEST_DIR
tt_status''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.path / 'worker-started').is_file())
        status = json.loads(result.stdout)
        self.assertEqual(status['health'], {'details_ready': False, 'error': 'details_unavailable'})
        self.assertGreater(status['timestamp'], time.time() - 5)
        self.assert_lock_free()

    def test_invalid_metadata_cannot_hide_core_status(self):
        result = self.execute('''tt_read_status_details() { printf '{}'; }
tt_pid_matches() { return 0; }
mkdir -p "$TT_SYS/class/net/tt0"
touch "$TT_ENABLED"
tt_status''')
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertTrue(status['process_running'])
        self.assertTrue(status['interface_up'])
        self.assertEqual(status['state'], 'tun_ready_unverified')
        self.assertFalse(status['health']['details_ready'])
        self.assertEqual(status['discovered_networks'], [])

    def test_degraded_metadata_is_explicit(self):
        result = self.execute('''tt_read_status_details() { printf '{"available":false,"error":"nvram_unavailable"}'; }
tt_status''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['health']['error'], 'nvram_unavailable')

    def test_status_request_does_not_mutate_networking_or_transaction(self):
        result = self.execute('''mkdir "$TT_CONFIG/transaction"
printf '{}' >"$TT_CONFIG/transaction/manifest.json"
tt_start() { echo UNEXPECTED >&2; return 99; }
tt_refresh() { echo UNEXPECTED >&2; return 99; }
tt_wire_dispatch ttm_do_0123456789abcdef_status''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED', result.stderr)
        op = json.loads((self.path / 'tmp/trusttunnel/operations/0123456789abcdef.json').read_text())
        self.assertEqual(op['action'], 'status')
        self.assertEqual(op['state'], 'succeeded')
        self.assertTrue((self.path / 'jffs/addons/trusttunnel/config/transaction/manifest.json').is_file())

    def test_runtime_uses_bounded_nvram_reader(self):
        for relative in ('inventory.sh', 'diagnostics.sh', 'compatibility.sh'):
            self.assertNotIn('nvram get ', (ROOT / 'addon/lib' / relative).read_text(), relative)
