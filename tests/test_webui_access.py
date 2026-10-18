"""The optional hardware checker with synthetic curl, no router or credentials."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class AccessCheckTests(unittest.TestCase):
    def test_unauthenticated_json_fails_and_response_is_withheld(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool=Path(tmp)/'curl'
            tool.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
case "$1" in --output) shift; printf '{"hostname":"SYNTHETIC-private-server"}' >"$1";; --dump-header) shift; printf 'Content-Type: application/json\\n' >"$1";; esac
shift
done
printf 200
''');tool.chmod(0o755)
            r=subprocess.run(['sh',str(ROOT/'tools/check-webui-access.sh'),'https://router.test:8443'],
                env=os.environ|{'PATH':tmp+os.pathsep+os.environ['PATH']},capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0)
            self.assertIn('FAIL anonymous',r.stderr)
            self.assertNotIn('SYNTHETIC-private-server',r.stdout+r.stderr)

    def test_authentication_rejection_passes_without_control_posts(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool=Path(tmp)/'curl';tool.write_text('#!/bin/sh\ncase "$*" in *POST*|*action_script*) exit 90;; esac\nprintf 403\n');tool.chmod(0o755)
            r=subprocess.run(['sh',str(ROOT/'tools/check-webui-access.sh'),'https://router.test:8443','user2.asp'],
                env=os.environ|{'PATH':tmp+os.pathsep+os.environ['PATH']},capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout.count('PASS'),3)
