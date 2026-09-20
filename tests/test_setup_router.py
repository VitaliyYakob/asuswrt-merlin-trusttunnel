import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools/setup-router.sh'


class SetupRouterTests(unittest.TestCase):
    def test_corrupt_archive_is_rejected_without_extraction(self):
        with tempfile.TemporaryDirectory() as work:
            archive = Path(work) / 'client.tar.gz'
            archive.write_bytes(b'not the official archive')
            result = subprocess.run(['sh', str(SCRIPT), '--verify-archive', str(archive)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SHA-256 mismatch', result.stderr)
            self.assertEqual(list(Path(work).iterdir()), [archive])

    def test_offline_sandbox_refuses_live_setup(self):
        result = subprocess.run(['sh', str(SCRIPT), '--lab-only'], env=os.environ | {'TT_ROOT': '/not-a-router'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('prohibited with TT_ROOT', result.stderr)

    def test_no_argument_does_not_install(self):
        result = subprocess.run(['sh', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Usage:', result.stderr)
