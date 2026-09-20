import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.base=self.path/'jffs/addons/trusttunnel'
        for name in ('config','lib','web'): (self.base/name).mkdir(parents=True)
        (self.base/'.trusttunnel-owned').write_text('trusttunnel-merlin-addon-v1\n')
        (self.base/'config/endpoint.json').write_text('SYNTHETIC_SECRET')
        (self.path/'tmp/trusttunnel').mkdir(parents=True)
        (self.path/'proc').mkdir(); (self.path/'proc/mounts').write_text('')
        self.binary=self.path/'opt/trusttunnel/bin/trusttunnel_client'
        self.binary.parent.mkdir(parents=True); self.binary.write_bytes(b'synthetic executable')
        Path(str(self.binary)+'.sha256').write_text(hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.init=self.path/'opt/etc/init.d/S99trusttunnel'
        self.init.parent.mkdir(parents=True); self.init.write_text('CTL=/jffs/addons/trusttunnel/trusttunnel.sh\n')
    def run_body(self, body):
        script='''TT_BASE="$TT_PROJECT/addon"
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/webui.sh"
. "$TT_BASE/lib/uninstall.sh"
# All live effects are overridden AFTER common.sh establishes PATH.
tt_disable() { return 0; }
tt_hooks() { return 0; }
tt_unmount_ui() { return 0; }
tt_pid_matches() { return 1; }
cru() { return 0; }
'''+body
        return subprocess.run(['busybox','ash','-c',script],env=os.environ|{'TT_PROJECT':str(ROOT),'TT_ROOT':str(self.path)},capture_output=True,text=True)
    def test_dry_run_changes_nothing_and_does_not_read_secrets(self):
        before={p.relative_to(self.path):p.read_bytes() for p in self.path.rglob('*') if p.is_file()}
        r=self.run_body('tt_disable() { echo BAD; return 99; }; tt_uninstall_plan')
        self.assertEqual(r.returncode,0,r.stderr); self.assertNotIn('SYNTHETIC_SECRET',r.stdout+r.stderr); self.assertNotIn('BAD',r.stdout)
        after={p.relative_to(self.path):p.read_bytes() for p in self.path.rglob('*') if p.is_file()}
        self.assertEqual(before,after)
    def test_purge_removes_only_owned_files_and_marked_staging(self):
        marked=self.path/'opt/ttm-setup-owned'; marked.mkdir(); (marked/'.trusttunnel-owned').write_text('trusttunnel-merlin-staging-v1\n')
        (marked/'private-backup').write_text('synthetic')
        unknown=self.path/'opt/ttm-setup-unknown'; unknown.mkdir(); (unknown/'keep').touch()
        foreign=self.binary.parent/'foreign'; foreign.write_text('keep')
        settings=self.path/'jffs/addons/custom_settings.txt'; settings.write_text('other_key value\nttm_policy synthetic\nttm_other preserved\n'); settings.chmod(0o640)
        r=self.run_body('tt_uninstall purge')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(self.base.exists()); self.assertFalse(self.binary.exists()); self.assertFalse(self.init.exists())
        self.assertFalse(marked.exists()); self.assertTrue(unknown.exists()); self.assertTrue(foreign.exists())
        self.assertEqual(settings.read_text(),'other_key value\nttm_other preserved\n')
        self.assertEqual(settings.stat().st_mode&0o777,0o640)
    def test_keep_preserves_private_data_and_binary(self):
        r=self.run_body('tt_uninstall keep'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.base/'config/endpoint.json').exists()); self.assertTrue(self.binary.exists()); self.assertFalse(self.init.exists())
    def test_failed_network_cleanup_never_deletes_recovery_files(self):
        r=self.run_body('tt_disable() { return 1; }; tt_uninstall purge')
        self.assertNotEqual(r.returncode,0); self.assertTrue(self.base.exists()); self.assertTrue(self.binary.exists()); self.assertTrue(self.init.exists())
    def test_pending_transaction_requires_resolution_before_cleanup(self):
        (self.base/'config/transaction').mkdir()
        r=self.run_body('tt_disable() { echo BAD; }; tt_uninstall purge')
        self.assertNotEqual(r.returncode,0); self.assertNotIn('BAD',r.stdout); self.assertTrue(self.binary.exists())
    def test_changed_binary_and_unknown_init_refused_before_disable(self):
        for which in ('binary','init'):
            with self.subTest(which=which):
                target=self.binary if which=='binary' else self.init
                original=target.read_bytes(); target.write_text('foreign modification')
                r=self.run_body('tt_disable() { echo BAD; }; tt_uninstall purge')
                self.assertNotEqual(r.returncode,0); self.assertNotIn('BAD',r.stdout); self.assertTrue(self.base.exists())
                target.write_bytes(original)
    def test_symlinked_and_mounted_removal_paths_are_refused(self):
        config=self.base/'config'; config.rename(self.base/'config-real'); config.symlink_to(self.base/'config-real',target_is_directory=True)
        r=self.run_body('tt_uninstall purge'); self.assertNotEqual(r.returncode,0); self.assertTrue(self.binary.exists())
        config.unlink(); (self.base/'config-real').rename(config)
        (self.path/'proc/mounts').write_text(f'device {self.base}/lib ext4 rw 0 0\n')
        r=self.run_body('tt_uninstall purge'); self.assertNotEqual(r.returncode,0); self.assertTrue(self.binary.exists())
    def test_cron_failure_retains_controller_for_retry(self):
        r=self.run_body('cru() { return 1; }; tt_uninstall purge')
        self.assertNotEqual(r.returncode,0); self.assertTrue(self.base.exists()); self.assertTrue(self.binary.exists())
    def test_wrapper_requires_confirmations_and_refuses_live_sandbox(self):
        env=os.environ|{'TT_ROOT':str(self.path)}
        for args,expected in [(['--purge'],2),(['--purge','--confirm-release-traffic','--confirm-delete-data'],1)]:
            r=subprocess.run(['sh',str(ROOT/'uninstall.sh'),*args],env=env,capture_output=True,text=True)
            self.assertEqual(r.returncode,expected); self.assertTrue(self.base.exists())
    def test_completed_purge_can_be_repeated_from_release(self):
        self.assertEqual(self.run_body('tt_uninstall purge').returncode,0)
        r=subprocess.run(['sh',str(ROOT/'uninstall.sh'),'--dry-run'],env=os.environ|{'TT_ROOT':str(self.path)},capture_output=True,text=True)
        self.assertEqual(r.returncode,0); self.assertIn('No files',r.stdout); self.assertFalse(self.base.exists())
    def test_absent_or_foreign_hook_is_not_created_or_rewritten(self):
        # Source original function, overriding only network/UI methods in run_body.
        r=self.run_body('tt_hook_edit services-start remove')
        self.assertEqual(r.returncode,0,r.stderr); self.assertFalse((self.path/'jffs/scripts/services-start').exists())
        hook=self.path/'jffs/scripts/services-start'; hook.write_text('#!/bin/sh\necho foreign\n'); hook.chmod(0o700)
        r=self.run_body('tt_hook_edit services-start remove')
        self.assertEqual(r.returncode,0); self.assertEqual(hook.stat().st_mode&0o777,0o700)
    def test_created_hook_removed_but_foreign_content_preserved(self):
        r=self.run_body('tt_hook_edit services-start install && tt_hook_edit services-start remove')
        self.assertEqual(r.returncode,0,r.stderr); self.assertFalse((self.path/'jffs/scripts/services-start').exists())
        hook=self.path/'jffs/scripts/services-start'; hook.write_text('#!/bin/sh\necho foreign\n')
        r=self.run_body('tt_hook_edit services-start install && chmod 700 "$TT_ROOT/jffs/scripts/services-start" && tt_hook_edit services-start remove')
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(hook.read_text(),'#!/bin/sh\necho foreign\n'); self.assertEqual(hook.stat().st_mode&0o777,0o700)
    def test_integration_audit_stops_purge_if_public_asset_remains(self):
        public=self.path/'www/user/trusttunnel'; public.mkdir(parents=True)
        (public/'status.json').write_text('{}')
        r=self.run_body('tt_uninstall purge')
        self.assertNotEqual(r.returncode,0); self.assertTrue(self.base.exists()); self.assertTrue(self.binary.exists())
        self.assertIn('cleanup incomplete',r.stderr)
    def test_ui_removal_preserves_other_addon_page_and_assets(self):
        public=self.path/'www/user/trusttunnel'; public.mkdir(parents=True)
        (public/'trusttunnel.js').touch(); (public/'foreign.txt').write_text('keep')
        ours=public.parent/'user2.asp'; ours.write_text('<!-- trusttunnel-merlin-page-v1 -->')
        other=public.parent/'user1.asp'; other.write_text('foreign')
        r=self.run_body('''. "$TT_BASE/lib/webui.sh"
tt_menu() { return 0; }
tt_unmount_ui''')
        self.assertEqual(r.returncode,0,r.stderr); self.assertFalse(ours.exists()); self.assertTrue(other.exists())
        self.assertFalse((public/'trusttunnel.js').exists()); self.assertTrue((public/'foreign.txt').exists())
    def test_queued_controller_cannot_recreate_paths_after_purge(self):
        r=self.run_body('''tt_uninstall purge || exit 99
TT_BASE="$TT_ROOT/jffs/addons/trusttunnel"
tt_lock''')
        self.assertNotEqual(r.returncode,0); self.assertFalse(self.base.exists()); self.assertFalse((self.path/'tmp/trusttunnel').exists())

    def test_orphan_hook_marker_refuses_cleanup_without_rewriting_file(self):
        hook=self.path/'jffs/scripts/services-start'; hook.parent.mkdir(parents=True)
        original='#!/bin/sh\n# END trusttunnel-merlin\necho foreign\n'; hook.write_text(original)
        r=self.run_body('tt_hook_edit services-start remove')
        self.assertNotEqual(r.returncode,0); self.assertEqual(hook.read_text(),original)
