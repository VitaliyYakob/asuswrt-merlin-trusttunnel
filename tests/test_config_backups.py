from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = os.environ | {"TT_ROOT": str(self.path / "sandbox"), "TT_BASE": str(ROOT / "addon")}

    def execute(self, body, *args):
        script = '. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/config.sh"\ntt_dirs || exit 91\n' + body
        return subprocess.run(["sh", "-c", script, "backup-test", *map(str, args)], env=self.env, text=True, capture_output=True)

    def test_reimport_backs_up_previous_endpoint_and_policy_privately(self):
        for kind in ("endpoint", "policy"):
            with self.subTest(kind=kind):
                old = json.loads((ROOT / "examples" / f"{kind}.example.json").read_text())
                new = copy.deepcopy(old)
                if kind == "endpoint": new["password"] = "new-private-password"
                else: new["sources"] = ["192.168.50.17/32"]
                first, second = self.path / f"{kind}-old.json", self.path / f"{kind}-new.json"
                first.write_text(json.dumps(old)); second.write_text(json.dumps(new))
                result = self.execute('tt_import "$1" "$2" && tt_import "$1" "$3"', kind, first, second)
                self.assertEqual(result.returncode, 0, result.stderr)
                dest = self.path / f"sandbox/jffs/addons/trusttunnel/config/{kind}.json"
                backup = Path(str(dest) + ".previous")
                def imported(value):
                    if kind == "endpoint": return value
                    return {"schema":3,"networks":[{"lan_if":value["lan_if"],"sources":value["sources"]}],
                            "block_ipv6_bridge":value["block_ipv6_bridge"],"table":value["table"],"priority":value["priority"]}
                self.assertEqual(json.loads(dest.read_text()), imported(new))
                self.assertEqual(json.loads(backup.read_text()), imported(old))
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                self.assertFalse((self.path / "sandbox/www").exists())

    def test_invalid_import_preserves_config_and_previous_backup(self):
        first = self.path / "endpoint.json"
        first.write_bytes((ROOT / "examples/endpoint.example.json").read_bytes())
        bad = self.path / "bad.json"; bad.write_text('{"password":"TEST-SECRET",bad')
        result = self.execute('tt_import endpoint "$1" && tt_import endpoint "$1" || exit 92\ntt_import endpoint "$2"', first, bad)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("TEST-SECRET", result.stderr + result.stdout)
        dest = self.path / "sandbox/jffs/addons/trusttunnel/config/endpoint.json"
        self.assertEqual(dest.read_bytes(), Path(str(dest) + ".previous").read_bytes())

    def test_restore_previous_does_not_overwrite_its_own_input(self):
        old = json.loads((ROOT / "examples/endpoint.example.json").read_text())
        first = self.path / "old.json"; first.write_text(json.dumps(old))
        new = old | {"password": "changed"}
        second = self.path / "new.json"; second.write_text(json.dumps(new))
        result = self.execute('tt_import endpoint "$1" && tt_import endpoint "$2" && tt_import endpoint "$TT_ENDPOINT.previous"', first, second)
        self.assertEqual(result.returncode, 0, result.stderr)
        dest = self.path / "sandbox/jffs/addons/trusttunnel/config/endpoint.json"
        self.assertEqual(json.loads(dest.read_text()), old)
        self.assertEqual(json.loads(Path(str(dest) + ".previous").read_text()), new)

    def test_backup_failure_leaves_active_configuration_intact(self):
        old = json.loads((ROOT / "examples/endpoint.example.json").read_text())
        first = self.path / "old.json"; first.write_text(json.dumps(old))
        new = old | {"password": "changed"}
        second = self.path / "new.json"; second.write_text(json.dumps(new))
        result = self.execute('tt_import endpoint "$1" || exit 92\nmkdir "$TT_ENDPOINT.previous"\ntt_import endpoint "$2"', first, second)
        self.assertNotEqual(result.returncode, 0)
        dest = self.path / "sandbox/jffs/addons/trusttunnel/config/endpoint.json"
        self.assertEqual(json.loads(dest.read_text()), old)

    def test_symlinked_configuration_is_not_overwritten(self):
        old = self.path / "outside.json"; old.write_bytes((ROOT / "examples/endpoint.example.json").read_bytes())
        result = self.execute('ln -s "$1" "$TT_ENDPOINT"\ntt_import endpoint "$1"', old)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.path / "sandbox/jffs/addons/trusttunnel/config/endpoint.json").is_symlink())

    def test_installer_backup_captures_own_files_and_init_before_overwrite(self):
        addon = self.path / "addon"; (addon / "lib").mkdir(parents=True)
        (addon / "lib/old.sh").write_text("old library")
        (addon / "trusttunnel.sh").write_text("old controller")
        init = self.path / "S99trusttunnel"; init.write_text("old init")
        result = self.execute('tt_backup_install "$1" "$2" || exit 93\nprintf "%s" "$TT_INSTALL_BACKUP"', addon, init)
        self.assertEqual(result.returncode, 0, result.stderr)
        backup = Path(result.stdout)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        (addon / "lib/old.sh").write_text("replacement")
        init.write_text("replacement")
        self.assertEqual((backup / "lib/old.sh").read_text(), "old library")
        self.assertEqual((backup / "trusttunnel.sh").read_text(), "old controller")
        self.assertEqual((backup / "S99trusttunnel").read_text(), "old init")

    def test_installer_backup_refuses_symlink_target(self):
        addon = self.path / "addon"; addon.mkdir()
        shared = self.path / "shared"; shared.mkdir()
        (addon / "lib").symlink_to(shared, target_is_directory=True)
        result = self.execute('tt_backup_install "$1" "$2"', addon, self.path / "missing-init")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(shared.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
