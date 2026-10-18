"""Firmware ash may omit the POSIX command builtin (observed on 388.12_2)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MerlinShellTests(unittest.TestCase):
    def test_native_merlin_dependencies_load_before_state(self):
        page = (ROOT / 'addon/trusttunnel_page.asp').read_text()
        self.assertLess(page.index('src="/js/jquery.js"'), page.index('src="/js/httpApi.js"'))
        self.assertLess(page.index('src="/js/httpApi.js"'), page.index('src="/state.js"'))

    def test_minimal_entware_jq_fails_before_install_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            sandbox = Path(folder)
            (sandbox / 'tools').mkdir()
            (sandbox / 'router/opt/etc/init.d').mkdir(parents=True)
            (sandbox / 'router/proc/self').mkdir(parents=True)
            (sandbox / 'router/proc/self/status').write_text('Uid:\t0\t0\t0\t0\n')
            for relative in ('install.sh', 'tools/router-platform.sh'):
                text = (ROOT / relative).read_text()
                for prefix in ('/opt/', '/jffs/', '/proc/', '/tmp/trusttunnel'):
                    text = text.replace(prefix, str(sandbox / 'router') + prefix)
                (sandbox / relative).write_text(text)
            fakebin=sandbox/'router/opt/bin'; fakebin.mkdir()
            nvram=fakebin/'nvram'
            nvram.write_text('#!/bin/sh\ncase "$2" in rc_support) echo am_addons;; jffs2_scripts) echo 1;; firmver) echo 3.0.0.4;; buildno) echo 388.12;; esac\n')
            nvram.chmod(0o755)
            before = sorted(str(p.relative_to(sandbox)) for p in sandbox.rglob('*'))
            result = subprocess.run(['busybox', 'ash', '-c', '''
id() { echo 0; }
uname() { case "$1" in -s) echo Linux;; -m) echo aarch64;; esac; }
opkg() { return 0; }
jq() { return 5; }
cru() { return 0; }
ip() { return 0; }
installer=$1
set -- --lab-only
. "$installer"
''', 'test', str(sandbox / 'install.sh')], cwd=sandbox, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('jq with regex support is required', result.stderr)
            self.assertEqual(before, sorted(str(p.relative_to(sandbox)) for p in sandbox.rglob('*')))

    def test_disabled_import_and_status_without_command_builtin(self):
        with tempfile.TemporaryDirectory() as folder:
            env = dict(os.environ, TT_ROOT=folder, TT_BASE=str(ROOT / 'addon'))
            result = subprocess.run(['busybox', 'ash', '-c', '''
command() { echo 'unexpected command builtin dependency' >&2; return 127; }
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/service.sh"
. "$TT_BASE/lib/diagnostics.sh"
tt_lock && tt_import endpoint "$1" && tt_status
''', 'test', str(ROOT / 'examples/endpoint.example.json')],
                env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('unexpected command builtin', result.stderr)
            self.assertTrue((Path(folder) / 'jffs/addons/trusttunnel/config/endpoint.json').is_file())

    def test_router_entrypoints_do_not_require_command_builtin(self):
        for path in [* (ROOT / 'addon').rglob('*.sh'), ROOT / 'install.sh', ROOT / 'tools/verify-client.sh']:
            with self.subTest(path=path.name):
                self.assertNotIn('command -v', path.read_text())
