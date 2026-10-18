"""Manifest hashes, source identity and release policy, without publishing anything."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class DistributionTests(unittest.TestCase):
    def test_package_manifest_binds_artifacts_and_supports_non_git_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for directory in ('addon','tools','packaging'):
                shutil.copytree(ROOT/directory,root/directory,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
            for name in ('VERSION','LICENSE','install.sh','uninstall.sh'):
                shutil.copy2(ROOT/name,root/name)
            r=subprocess.run(['python3',str(root/'tools/package.py')],text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            manifest=json.loads((root/'dist/manifest.json').read_text())
            self.assertIsNone(manifest['source']['commit'])
            self.assertRegex(manifest['source']['sha256'],r'^[a-f0-9]{64}$')
            self.assertEqual(len(manifest['artifacts']),3)
            for artifact in manifest['artifacts']:
                data=(root/'dist'/artifact['name']).read_bytes()
                self.assertEqual(len(data),artifact['size'])
                self.assertEqual(hashlib.sha256(data).hexdigest(),artifact['sha256'])
            checks=(root/'dist/SHA256SUMS').read_text()
            self.assertIn(hashlib.sha256((root/'dist/manifest.json').read_bytes()).hexdigest()+'  manifest.json',checks)

    def test_release_checks_exact_tag_ci_and_full_browser_suite_before_signing(self):
        text=(ROOT/'.github/workflows/release.yml').read_text()
        self.assertIn('head_sha=$sha',text)
        self.assertIn('make test lint browser-test package',text)
        self.assertLess(text.index('make test lint browser-test package'),text.index('uses: actions/attest@'))
        self.assertLess(text.index('uses: actions/attest@'),text.index('gh release create'))
        self.assertIn('--draft --prerelease',text)
        self.assertIn('dist/manifest.json dist/attestation.bundle.json',text)
