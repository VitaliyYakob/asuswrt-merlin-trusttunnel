import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class HookBackupFailure(unittest.TestCase):
    def test_failed_backup_does_not_modify_hook(self):
        with tempfile.TemporaryDirectory() as folder:
            sandbox=Path(folder)
            hook=sandbox/'jffs/scripts/services-start'
            hook.parent.mkdir(parents=True)
            original='#!/bin/sh\n# synthetic foreign addon\necho existing\n'
            hook.write_text(original)
            env=dict(os.environ, TT_ROOT=str(sandbox), TT_TEST_BASE=str(ROOT/'addon'))
            result=subprocess.run(['sh','-c','''TT_BASE=$TT_TEST_BASE
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/webui.sh"
tt_dirs || exit 90
cp() { return 1; }
tt_hook_edit services-start install
'''],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(hook.read_text(),original)
            self.assertIn('hook backup failed',result.stderr)
            self.assertFalse(list(hook.parent.glob('.ttm-hook.*')))
            self.assertFalse(list((sandbox/'tmp/trusttunnel').glob('hook-body.*')))

if __name__=='__main__':unittest.main()
