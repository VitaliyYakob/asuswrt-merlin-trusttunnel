"""Elapsed process time uses Linux USER_HZ and uptime, never wall time."""
import json, os, struct, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class UptimeTests(unittest.TestCase):
    def test_monotonic_elapsed_and_missing_auxv(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc=Path(tmp)/'proc';(proc/'self').mkdir(parents=True)
            (proc/'self/auxv').write_bytes(struct.pack('<QQQQ',17,100,0,0))
            (proc/'uptime').write_text('186000.7 0.0\n')
            script='''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/service.sh"
tt_pid_matches() { TT_START=100000; return 0; }
date() { echo CALENDAR_MUST_NOT_BE_USED >&2; return 99; }
tt_client_uptime'''
            env=os.environ|{'TT_ROOT':tmp,'TT_BASE':str(ROOT/'addon')}
            r=subprocess.run(['busybox','ash','-c',script],capture_output=True,text=True,env=env)
            self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout),185000);self.assertNotIn('CALENDAR',r.stderr)
            (proc/'self/auxv').unlink()
            r=subprocess.run(['busybox','ash','-c',script],capture_output=True,text=True,env=env)
            self.assertEqual(r.returncode,0,r.stderr);self.assertIsNone(json.loads(r.stdout))
