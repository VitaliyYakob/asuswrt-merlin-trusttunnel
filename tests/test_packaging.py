"""Offline IPK/installer regressions. All mutable paths and OS commands are isolated."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_ipk', ROOT / 'tools/build-ipk.py')
BUILDER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BUILDER)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name)
        self.ipk = BUILDER.build(ROOT, self.work)
        with tarfile.open(self.ipk) as outer:
            self.metadata = outer.extractfile('./control.tar.gz').read()
            self.payload = outer.extractfile('./data.tar.gz').read()

    def tearDown(self):
        self.temp.cleanup()

    def members(self, content):
        with tarfile.open(fileobj=io.BytesIO(content)) as archive:
            return {member.name: (archive.extractfile(member).read(), member.mode)
                    for member in archive.getmembers() if member.isfile()}

    def test_entware_outer_format_and_dependencies(self):
        with tarfile.open(self.ipk) as archive:
            self.assertEqual(archive.getnames(), ['./control.tar.gz', './data.tar.gz', './debian-binary'])
            self.assertEqual(archive.extractfile('./debian-binary').read(), b'2.0\n')
        control = self.members(self.metadata)['./control'][0].decode()
        self.assertIn('Architecture: aarch64-3.10\n', control)
        for dependency in BUILDER.DEPENDENCIES:
            self.assertIn(dependency, control)

    def test_sources_only_private_files_and_cli_absent(self):
        files = self.members(self.payload)
        prefix = './opt/share/asuswrt-merlin-trusttunnel/'
        self.assertTrue(all(name.startswith(prefix) for name in files))
        self.assertIn(prefix + 'addon/trusttunnel.sh', files)
        self.assertEqual(files[prefix + 'addon/trusttunnel.sh'][1], 0o755)
        self.assertIn(prefix + 'addon/share/client-release-key.asc', files)
        self.assertFalse(any(part in name for name in files for part in
                             ('client.toml', 'endpoint.json', 'Template/', 'node_modules', 'install-online.sh')))
        self.assertFalse(any(Path(name).name == 'trusttunnel_client' for name in files))

    def test_fifo_dependency_is_declared_for_firmware_without_mkfifo(self):
        control = self.members(self.metadata)['./control'][0].decode()
        dependencies = next(line.removeprefix('Depends: ') for line in control.splitlines()
                            if line.startswith('Depends: ')).split(', ')
        self.assertIn('coreutils-mkfifo', dependencies)

    def test_reproducible_and_online_hash_matches(self):
        digest = hashlib.sha256(self.ipk.read_bytes()).hexdigest()
        second = BUILDER.build(ROOT, self.work / 'second')
        self.assertEqual(self.ipk.read_bytes(), second.read_bytes())
        online = BUILDER.online_installer(ROOT, self.ipk)
        self.assertIn('IPK_SHA256=' + digest, online)
        self.assertIn('IPK=' + self.ipk.name, online)
        self.assertEqual((ROOT / 'install-online.sh').read_text(), online)
        self.assertNotIn('@PLATFORM@', online)

    def test_ipk_does_not_depend_on_python_default_compression_level(self):
        native_compress = BUILDER.gzip.compress
        packages = []
        for default in (6, 9):
            def compress(data, compresslevel=default, *, mtime=0):
                return native_compress(data, compresslevel=compresslevel, mtime=mtime)
            with patch.object(BUILDER.gzip, 'compress', compress):
                packages.append(BUILDER.build(ROOT, self.work / str(default)).read_bytes())
        self.assertEqual(packages[0], packages[1])

    def test_all_maintainer_scripts_do_nothing_for_offline_root(self):
        for name in ('preinst', 'postinst', 'prerm'):
            text, mode = self.members(self.metadata)['./' + name]
            script = self.work / name
            script.write_bytes(text)
            result = subprocess.run(['sh', str(script), 'install'], capture_output=True, text=True,
                                    env=os.environ | {'IPKG_INSTROOT': str(self.work / 'offline'), 'TT_ROOT': '/forbidden'})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(mode, 0o755)
            self.assertFalse((self.work / 'offline').exists())

    def test_preinst_refuses_development_sandbox(self):
        script = self.work / 'preinst'
        script.write_bytes(self.members(self.metadata)['./preinst'][0])
        result = subprocess.run(['sh', str(script), 'install'], capture_output=True, text=True,
                                env=os.environ | {'TT_ROOT': str(self.work)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('prohibited with TT_ROOT', result.stderr)

    def test_builder_refuses_secret_and_symlink_in_payload(self):
        clone = self.work / 'source'
        clone.mkdir()
        for directory in ('addon', 'tools'):
            shutil.copytree(ROOT / directory, clone / directory)
        for name in ('VERSION', 'LICENSE', 'install.sh', 'uninstall.sh'):
            shutil.copy2(ROOT / name, clone / name)
        for name in ('endpoint.json', 'client.toml', 'private.key'):
            file = clone / 'addon' / name
            file.write_text('synthetic test; never a credential')
            with self.assertRaises(ValueError):
                BUILDER.payload(clone)
            file.unlink()
        (clone / 'addon/link').symlink_to(ROOT / 'VERSION')
        with self.assertRaises(ValueError):
            BUILDER.payload(clone)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name)
        self.root = self.work / 'router'
        self.root.mkdir()
        self.bin = self.root / 'opt/bin'
        self.bin.mkdir(parents=True)
        (self.root / 'opt/etc/init.d').mkdir(parents=True)
        self.config = self.root / 'jffs/addons/trusttunnel/config'
        self.config.mkdir(parents=True)
        (self.root / 'proc/self').mkdir(parents=True)
        (self.root / 'proc/self/status').write_text('Uid:\t0\t0\t0\t0\n')
        self.log = self.work / 'calls'
        self.shim('uname', 'case "$1" in -s) echo Linux;; -m) echo aarch64;; esac')
        self.shim('nvram', 'case "$2" in rc_support) echo "am_addons bcmhnd";; firmver) echo 3.0.0.4;; buildno) echo 388.12;; jffs2_scripts) echo 1;; esac')
        self.shim('opkg', 'if [ "$1" = print-architecture ]; then echo "arch aarch64-3.10 160"; else exit 91; fi')
        self.shim('gpg', 'exit 92')
        self.shim('timeout', 'if [ "$1" = -k ]; then shift 3; exec "$@"; fi; exit 94')
        self.source = self.work / 'source'
        (self.source / 'tools').mkdir(parents=True)
        (self.source / 'addon/lib').mkdir(parents=True)
        (self.source / 'addon/share').mkdir(parents=True)
        shutil.copy2(ROOT / 'addon/lib/backup.sh', self.source / 'addon/lib/backup.sh')
        for name in BUILDER.TOOLS:
            (self.source / 'tools' / name).write_text(self.isolate((ROOT / 'tools' / name).read_text()))
        (self.source / 'install.sh').write_text('#!/bin/sh\nprintf "native-disabled-install\\n" >>"$CALL_LOG"\n')

    def tearDown(self):
        self.temp.cleanup()

    def isolate(self, text):
        for prefix in ('/opt/', '/jffs/', '/proc/', '/tmp/trusttunnel'):
            text = text.replace(prefix, str(self.root) + prefix)
        return text

    def shim(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" "' + name + ':$*" >>"$CALL_LOG"\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, script, *args):
        return subprocess.run(['sh', str(script), *args], capture_output=True, text=True,
                              env=os.environ | {'CALL_LOG': str(self.log), 'TT_ROOT': '', 'IPKG_INSTROOT': ''})

    def calls(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_firmware_floor_and_newer_branch(self):
        library = self.source / 'tools/router-platform.sh'
        for branch, build, expected in [('3.0.0.4', '384.15', 1), ('3.0.0.4', '388.11', 1),
                                        ('3.0.0.4', '388.12', 0), ('3.0.0.4', '388.12_2', 1),
                                        ('3.0.0.6', '102.5', 0), ('invalid', '388.12', 1),
                                        ('3.0.0.4', '388.12;unsafe', 1)]:
            result = subprocess.run(['sh', '-c', '. "$1"; tt_install_firmware_supported "$2" "$3"',
                                     'test', str(library), branch, build], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_ipk_reinstall_preserves_cli_and_never_reenters_opkg(self):
        binary = self.bin.parent / 'trusttunnel/bin/trusttunnel_client'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'synthetic previously verified client 1.1.7')
        binary.with_name(binary.name + '.sha256').write_text(hashlib.sha256(binary.read_bytes()).hexdigest() + '\n')
        (self.config.parent / '.trusttunnel-owned').write_text('trusttunnel-merlin-addon-v1\n')
        before = binary.read_bytes()
        result = self.run_script(self.source / 'tools/setup-router.sh', '--lab-only', '--from-ipk')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(binary.read_bytes(), before)
        self.assertIn('Preserving existing verified', result.stdout)
        self.assertNotIn('opkg:', self.calls())
        self.assertNotIn('curl:', self.calls())
        self.assertIn('native-disabled-install', self.calls())

    def test_missing_mkfifo_is_refused_before_client_or_native_install(self):
        script = self.source / 'tools/setup-router.sh'
        script.write_text(script.read_text().replace('set -eu\n',
                          'set -eu\ntype() { [ "$1" != mkfifo ]; }\n', 1))
        result = self.run_script(script, '--lab-only', '--from-ipk')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing utility: mkfifo', result.stderr)
        self.assertNotIn('native-disabled-install', self.calls())
        self.assertNotIn('curl:', self.calls())
        self.assertFalse((self.root / 'opt/trusttunnel/bin/trusttunnel_client').exists())

    def test_dependency_preparation_installs_mkfifo_without_global_upgrade(self):
        self.shim('opkg', '''case "$1" in
print-architecture) echo 'arch aarch64-3.10 160';;
list-installed|update) :;;
install) case " $* " in *' coreutils-mkfifo '*) :;; *) exit 89;; esac;;
*) exit 98;; esac''')
        result = self.run_script(self.source / 'tools/prepare-entware.sh', '--lab-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('coreutils-mkfifo', self.calls())
        self.assertNotIn('opkg:upgrade', self.calls())

    def test_corrupt_existing_client_is_not_overwritten(self):
        binary = self.bin.parent / 'trusttunnel/bin/trusttunnel_client'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'synthetic corrupt client')
        binary.with_name(binary.name + '.sha256').write_text('0' * 64 + '\n')
        (self.config.parent / '.trusttunnel-owned').write_text('trusttunnel-merlin-addon-v1\n')
        result = self.run_script(self.source / 'tools/setup-router.sh', '--lab-only', '--from-ipk')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown or corrupt', result.stderr)
        self.assertNotIn('native-disabled-install', self.calls())
        self.assertEqual(binary.read_bytes(), b'synthetic corrupt client')

    def test_failed_full_jq_install_restores_previous_package(self):
        self.shim('opkg', '''case "$1" in
print-architecture) echo 'arch aarch64-3.10 160';;
list-installed) echo 'jq - test';;
update|remove) :;;
download) printf 'synthetic package' >"${2}_test_aarch64-3.10.ipk";;
install) case "$2" in */jq-full_*) exit 12;; */jq_*) exit 0;; *) exit 99;; esac;;
*) exit 98;; esac''')
        result = self.run_script(self.source / 'tools/prepare-entware.sh', '--lab-only')
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls()
        self.assertLess(calls.index('opkg:download jq-full'), calls.index('opkg:remove jq'))
        installs = [line for line in calls.splitlines() if line.startswith('opkg:install ')]
        self.assertEqual(len(installs), 2)
        self.assertIn('/jq-full_', installs[0])
        self.assertIn('/jq_', installs[1])
        self.assertTrue(any((self.root / 'opt').glob('ttm-setup-dependencies.*/jq_test_*.ipk')))

    def first_install_fixture(self, signed=True):
        binary = b'synthetic ARM64 client; never executed'
        # setup expects official names without ./; this tar fixture is independent.
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as tar:
            for name, data in [('trusttunnel_client', binary), ('trusttunnel_client.sig', b'synthetic signature')]:
                member = tarfile.TarInfo('trusttunnel_client-v1.1.5-linux-aarch64/' + name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        archive = stream.getvalue()
        download = self.work / 'client.tar.gz'
        download.write_bytes(archive)
        digest = hashlib.sha256(binary).hexdigest()
        script = self.source / 'tools/setup-router.sh'
        script.write_text(script.read_text().replace('db17e4e2f9712de269b8e3196491324487fe9077c223e50b602668d888b5e81f', hashlib.sha256(archive).hexdigest())
                          .replace('0eceaaf0c7afd07b10dd66262c7812ec52aa0ed631d65373f58f4b8318fb5869', digest))
        self.shim('curl', 'while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; cp "' + str(download) + '" "$1"; exit 0; fi; shift; done; exit 1')
        verifier = self.source / 'tools/verify-client.sh'
        verifier.write_text('exit 15\n' if not signed else 'sha256sum "$1" | awk \'{print $1}\'\n')
        target = self.root / 'opt/trusttunnel/bin/trusttunnel_client'
        (self.source / 'tools/install-client.sh').write_text('mkdir -p "' + str(target.parent) + '"\ncp "$1" "' + str(target) + '"\nprintf "%s\\n" "$2" >"' + str(target) + '.sha256"\n')
        (self.root / 'tmp/trusttunnel').mkdir(parents=True)
        return target, digest

    def test_first_install_records_actual_date_and_keeps_vpn_disabled(self):
        target, digest = self.first_install_fixture()
        result = self.run_script(self.source / 'tools/setup-router.sh', '--lab-only', '--from-ipk')
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads((self.config / 'client-release.json').read_text())
        self.assertEqual(metadata['sha256'], digest)
        self.assertEqual(metadata['version'], '1.1.5')
        self.assertGreater(metadata['installed_at'], 0)
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), digest)
        self.assertFalse((self.config / 'enabled').exists())
        self.assertNotIn('opkg:', self.calls())
        self.assertEqual((self.config / 'client-release.json').stat().st_mode & 0o777, 0o600)

    def test_first_install_bad_signature_does_not_install_binary(self):
        target, _ = self.first_install_fixture(signed=False)
        result = self.run_script(self.source / 'tools/setup-router.sh', '--lab-only', '--from-ipk')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())
        self.assertFalse((self.config / 'client-release.json').exists())
        self.assertNotIn('native-disabled-install', self.calls())

    def test_active_or_pending_state_blocks_before_package_commands(self):
        for state in ('enabled', 'paused', 'transaction', 'client-update-journal.json'):
            marker = self.config / state
            marker.write_text('test')
            result = self.run_script(self.source / 'tools/setup-router.sh', '--lab-only', '--from-ipk')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('opkg:', self.calls())
            self.assertNotIn('native-disabled-install', self.calls())
            marker.unlink()

    def test_online_wrong_digest_never_extracts_or_installs(self):
        script = self.work / 'online.sh'
        script.write_text(self.isolate((ROOT / 'install-online.sh').read_text()))
        self.shim('curl', 'while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; printf "corrupt download" >"$1"; exit 0; fi; shift; done; exit 1')
        self.shim('tar', 'exit 93')
        result = self.run_script(script, '--lab-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('IPK SHA-256 mismatch', result.stderr)
        self.assertNotIn('tar:', self.calls())
        self.assertNotIn('opkg:install', self.calls())

    def test_all_installers_refuse_offline_sandbox(self):
        for relative, args in [('install.sh', ['--lab-only']), ('install-online.sh', ['--lab-only']),
                               ('tools/prepare-entware.sh', ['--lab-only']),
                               ('tools/install-client.sh', ['nonexistent', '0' * 64])]:
            result = subprocess.run(['sh', str(ROOT / relative), *args], capture_output=True, text=True,
                                    env=os.environ | {'TT_ROOT': str(self.work)})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('prohibited with TT_ROOT', result.stderr)


if __name__ == '__main__':
    unittest.main()
