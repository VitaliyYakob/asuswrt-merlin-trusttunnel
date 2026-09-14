"""Offline probes for the DNS transit local-address collision check."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class DnsPreflight(unittest.TestCase):
    def execute(self, body):
        with tempfile.TemporaryDirectory() as folder:
            env=dict(os.environ,TT_ROOT=folder,TT_BASE=str(ROOT/'addon'))
            return subprocess.run(['sh','-c','. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/service.sh"\n'+body],env=env,capture_output=True,text=True)

    def test_offline_sandbox_never_inspects_host_addresses(self):
        result=self.execute('ip() { echo HOST-NETWORK-CALL >&2; return 99; }; tt_check_dns_transit')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('HOST-NETWORK-CALL',result.stderr)

    def test_assigned_transit_address_is_rejected(self):
        result=self.execute('''ip() { printf '3: br0 inet 192.0.2.53/24 scope global br0\\n'; }
TT_ROOT=
tt_check_dns_transit''')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('conflicts',result.stderr)

    def test_nonconflicting_addresses_are_accepted(self):
        result=self.execute('''ip() { printf '3: br0 inet 192.168.50.1/24 scope global br0\\n4: br1 inet 192.0.2.5/24 scope global br1\\n'; }
TT_ROOT=
tt_check_dns_transit''')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_failed_read_does_not_assume_the_address_is_available(self):
        result=self.execute('ip() { return 1; }; TT_ROOT=; tt_check_dns_transit')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('cannot check',result.stderr)

if __name__=='__main__':unittest.main()
