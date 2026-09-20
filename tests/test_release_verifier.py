"""Verifier control flow with a GPG stub; not verification of a real release."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
FINGERPRINT='28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6'


class ReleaseVerifierTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        for name in ('binary','signature','public-key'): (self.path/name).write_bytes(b'synthetic fixture')
        stub=self.path/'gpg'
        stub.write_text('''#!/bin/sh
case " $* " in *" --import "*) exit 0;; esac
printf '[GNUPG:] VALIDSIG %s 2026-09-20 0 0 4 0 1 8 00 %s\n' "$TEST_FINGERPRINT" "$TEST_FINGERPRINT"
exit "$TEST_EXIT"
'''); stub.chmod(0o755)

    def verify(self,fingerprint=FINGERPRINT,status='0'):
        return subprocess.run(['sh',str(ROOT/'tools/verify-client.sh'),*(str(self.path/name) for name in ('binary','signature','public-key'))],
                              env=os.environ|{'PATH':str(self.path)+':'+os.environ['PATH'],'TEST_FINGERPRINT':fingerprint,'TEST_EXIT':status},capture_output=True,text=True)

    def test_pinned_fingerprint_allows_only_digest_of_verified_copy(self):
        result=self.verify()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),hashlib.sha256(b'synthetic fixture').hexdigest())

    def test_different_valid_signer_is_rejected(self):
        result=self.verify('A'*40)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')

    def test_gpg_failure_is_not_overridden_by_status_output(self):
        result=self.verify(status='1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')
