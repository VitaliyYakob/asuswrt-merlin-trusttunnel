import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WebUIAssetsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.public = self.path / 'www/user/trusttunnel'
        self.public.mkdir(parents=True)

    def run_body(self, body):
        return subprocess.run(['busybox', 'ash', '-c', '''
TT_BASE="$TT_TEST_BASE"
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/webui.sh"
. "$TT_BASE/lib/uninstall.sh"
# No live networking: only publication/removal in TT_ROOT below.
''' + body], env=os.environ | {'TT_ROOT': str(self.path), 'TT_TEST_BASE': str(ROOT / 'addon')},
                              text=True, capture_output=True)

    def test_page_stylesheet_is_published_and_uses_a_native_css_path(self):
        result = self.run_body('tt_publish_ui_assets')
        self.assertEqual(result.returncode, 0, result.stderr)
        page = (ROOT / 'addon/trusttunnel_page.asp').read_text()
        href = re.search(r'<link rel="stylesheet" href="(/user/trusttunnel/[^\"]+)">', page)[1]
        # On the real AX86U, httpd returned 404 for .css?v=..., 200 for .css.
        self.assertNotIn('?', href)
        self.assertNotIn('#', href)
        self.assertIn((ROOT / 'VERSION').read_text().strip(), href)
        published = self.path / 'www' / href.lstrip('/')
        self.assertEqual(published.read_bytes(), (ROOT / 'addon/web/trusttunnel.css').read_bytes())
        self.assertEqual(published.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.public.stat().st_mode & 0o777, 0o755)

    def test_publication_refuses_symlinked_versioned_css(self):
        victim = self.path / 'foreign.css'
        victim.write_text('keep')
        version = (ROOT / 'VERSION').read_text().strip()
        (self.public / f'trusttunnel.{version}.css').symlink_to(victim)
        self.assertNotEqual(self.run_body('tt_publish_ui_assets').returncode, 0)
        self.assertEqual(victim.read_text(), 'keep')

    def test_removal_cleans_marked_stylesheets_only(self):
        css = (ROOT / 'addon/web/trusttunnel.css').read_text()
        owned = [self.public / 'trusttunnel.0.3.1-alpha.9.css', self.public / 'trusttunnel.0.3.1-alpha.10.css']
        for file in owned:
            file.write_text(css)
        foreign = self.public / 'trusttunnel.9.9.9.css'
        foreign.write_text('/* third-party asset */')
        unrelated = self.public / 'foreign.css'
        unrelated.write_text(css)
        result = self.run_body('tt_menu() { return 0; }; tt_unmount_ui')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not file.exists() for file in owned))
        self.assertTrue(foreign.exists())
        self.assertTrue(unrelated.exists())

    def test_uninstall_audit_rejects_remaining_marked_stylesheet(self):
        (self.public / 'trusttunnel.0.3.1-alpha.9.css').write_text((ROOT / 'addon/web/trusttunnel.css').read_text())
        result = self.run_body('''tt_pid_matches() { return 1; }
cru() { return 0; }
TT_U_INIT="$TT_ROOT/opt/etc/init.d/S99trusttunnel"
tt_uninstall_audit''')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
