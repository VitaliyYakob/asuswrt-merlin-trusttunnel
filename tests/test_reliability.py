"""Read/write isolation for clock, preflight and install-failure regressions."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ | {'TT_ROOT':str(self.root), 'TT_BASE':str(ROOT/'addon')}
        proc = self.root/'proc/sys/kernel/random'; proc.mkdir(parents=True)
        (proc/'boot_id').write_text('boot-one')
        (self.root/'proc/uptime').write_text('1000.25 0.0\n')

    def shell(self, code):
        return subprocess.run(['busybox','ash','-c','. "$TT_BASE/lib/common.sh"\ntt_dirs\n'+code],
            env=self.env, text=True, capture_output=True, timeout=20)

    def test_monotonic_deadline_ignores_wall_clock_and_expires_after_reboot(self):
        result=self.shell('''tt_timer 180 | jq '{timer:.}' >"$TT_RUN/trial.json"
date() { printf 9999999999; }
tt_timer_remaining "$TT_RUN/trial.json"
printf '1100.0 0.0' >"$TT_PROC/uptime"
date() { printf 1; }
tt_timer_remaining "$TT_RUN/trial.json"
printf boot-two >"$TT_PROC/sys/kernel/random/boot_id"
tt_timer_remaining "$TT_RUN/trial.json"''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines(),['180','80','0'])

    def test_missing_or_legacy_clock_expires_conservatively(self):
        result=self.shell('''printf '{"deadline":9999999999}' >"$TT_RUN/trial.json"
tt_timer_remaining "$TT_RUN/trial.json"
rm "$TT_PROC/uptime"
tt_timer_remaining "$TT_RUN/trial.json"''')
        self.assertEqual(result.stdout.splitlines(),['0','0'])

    def test_install_nvram_is_bounded_and_discards_partial_stdout(self):
        fake=self.root/'bin'; fake.mkdir()
        script=fake/'nvram'
        script.write_text('#!/bin/sh\ntrap "" TERM\nprintf PARTIAL-SECRET\nwhile :; do sleep 1; done\n'); script.chmod(0o755)
        env=self.env | {'PATH':str(fake)+os.pathsep+os.environ['PATH']}
        started=time.monotonic()
        result=subprocess.run(['sh','-c','. "$1"; tt_install_nvram rc_support','test',str(ROOT/'tools/router-platform.sh')],
            env=env,text=True,capture_output=True,timeout=8)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('PARTIAL-SECRET',result.stdout+result.stderr)
        self.assertLess(time.monotonic()-started,6)

    def test_binary_log_burst_is_bounded_and_fifo_is_cleaned(self):
        work=self.root/'log'; work.mkdir(); os.mkfifo(work/'pipe')
        output=self.root/'client.log'; output.touch(mode=0o600)
        child=subprocess.Popen(['busybox','ash',str(ROOT/'addon/lib/log-writer.sh'),str(work),str(output)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            with (work/'pipe').open('wb',buffering=0) as stream:
                stream.write(b'X'*(3*1048576)+b'end-of-burst')
            _,err=child.communicate(timeout=20)
            self.assertEqual(child.returncode,0,err.decode())
        finally:
            if child.poll() is None: child.kill(); child.communicate()
        self.assertLessEqual(output.stat().st_size,1048576)
        self.assertTrue(output.read_bytes().endswith(b'end-of-burst'))
        self.assertFalse(work.exists())
        self.assertEqual(output.stat().st_mode & 0o777,0o600)

    def test_metrics_read_only_fake_proc_and_exclude_guest_cpu_double_count(self):
        proc=self.root/'proc'; (proc/'123').mkdir()
        stat=['123','(trusttunnel_client)','S']+['0']*19
        stat[13]='30';stat[14]='20'
        (proc/'123/stat').write_text(' '.join(stat))
        (proc/'123/status').write_text('VmRSS: 2048 kB\n')
        (proc/'stat').write_text('cpu 100 10 20 800 30 5 5 30 200 100\ncpu0 1\ncpu1 1\n')
        r=self.shell('''. "$TT_BASE/lib/service.sh"
tt_pid_matches() { TT_PID=123; TT_START=456; return 0; }
tt_process_metrics''')
        import json
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout),dict(process_start='456',rss_kib=2048,cpu_ticks=50,system_ticks=1000,cpu_count=2))
        r=self.shell('''. "$TT_BASE/lib/service.sh"
tt_pid_matches() { TT_PID=123; TT_START=456; return 0; }
awk() { return 1; }
tt_process_metrics''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIsNone(json.loads(r.stdout), 'a raced optional proc read must degrade to null')

    def install_case(self, fail):
        src=self.root/'source'; src.mkdir()
        shutil.copytree(ROOT/'addon',src/'addon')
        shutil.copy2(ROOT/'uninstall.sh',src/'uninstall.sh')
        dest=self.root/'installed'; (dest/'config').mkdir(parents=True)
        for d in ('lib','share','web'):
            (dest/d).mkdir(); (dest/d/'old').write_text('old-'+d)
        for f in ('trusttunnel.sh','trusttunnel_page.asp','uninstall.sh'):
            (dest/f).write_text('old-'+f)
        (dest/'.trusttunnel-owned').write_text('trusttunnel-merlin-addon-v1\n')
        private=dest/'config/endpoint.json'; private.write_text('synthetic-secret'); private.chmod(0o600)
        init=self.root/'S99trusttunnel'; init.write_text('old-init'); init.chmod(0o711)
        code='''. "$TT_BASE/lib/install-transaction.sh"
tt_install_ui_cleanup() { printf cleanup >>"$TT_ROOT/effects"; }
tt_install_ui() { [ "$TT_BASE" != fail ]; }
'''
        if fail in ('ui','ui_disk'):
            code+='tt_install_ui() { if [ ! -f "$TT_ROOT/tried" ]; then touch "$TT_ROOT/tried"; return 1; fi; return 0; }\n'
        elif fail=='move':
            code+='''mv() { case "$1" in */new/share) return 12;; esac; command mv "$@"; }
'''
        if fail=='ui_disk':
            code+='cp() { for last; do :; done; [ \"$last\" != \"$TT_ROOT/installed/config\" ] || return 28; command cp \"$@\"; }\n'.replace('\\"','"')
        code+=f'tt_install_transaction "{src}" "{dest}" "{init}"'
        result=self.shell(code)
        self.assertEqual(private.read_text(),'synthetic-secret')
        self.assertEqual(private.stat().st_mode & 0o777,0o600)
        return dest,init,result

    def test_failed_ui_install_restores_old_files_config_and_init(self):
        dest,init,result=self.install_case('ui')
        self.assertNotEqual(result.returncode,0,result.stderr)
        for d in ('lib','share','web'): self.assertEqual((dest/d/'old').read_text(),'old-'+d)
        self.assertEqual((dest/'trusttunnel.sh').read_text(),'old-trusttunnel.sh')
        self.assertEqual(init.read_text(),'old-init'); self.assertEqual(init.stat().st_mode & 0o777,0o711)
        self.assertFalse((dest/'config/LAB_ONLY_ACKNOWLEDGED').exists())

    def test_failed_install_restores_configuration_without_allocating_a_third_copy(self):
        dest,init,result=self.install_case('ui_disk')
        self.assertNotEqual(result.returncode,0,result.stderr)
        self.assertEqual((dest/'config/endpoint.json').read_text(),'synthetic-secret')
        self.assertEqual(init.read_text(),'old-init')

    def test_failed_copy_phase_restores_already_switched_directories(self):
        dest,init,result=self.install_case('move')
        self.assertNotEqual(result.returncode,0,result.stderr)
        for d in ('lib','share','web'): self.assertEqual((dest/d/'old').read_text(),'old-'+d)
        self.assertEqual(init.read_text(),'old-init')

    def test_success_retains_private_backup_without_starting_client(self):
        dest,init,result=self.install_case('success')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((dest/'trusttunnel.sh').read_bytes(),(ROOT/'addon/trusttunnel.sh').read_bytes())
        records=list((dest/'install-backups').glob('install-*'))
        self.assertEqual(len(records),1)
        self.assertEqual((records[0]/'old/lib/old').read_text(),'old-lib')
        self.assertEqual(init.stat().st_mode & 0o777,0o755)
        self.assertFalse((dest/'config/enabled').exists())
