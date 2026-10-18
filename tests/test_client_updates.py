"""Offline updater control flow; GPG and router effects are mocked explicitly."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SIGNER = '28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6'


def release(tag='v1.1.7', pre=False, date='2026-09-24T00:00:00Z'):
    name = f'trusttunnel_client-{tag}-linux-aarch64.tar.gz'
    return dict(id=1, tag_name=tag, draft=False, prerelease=pre, published_at=date,
                assets=[dict(name=name, digest='sha256:'+'a'*64, size=100,
                             browser_download_url=f'https://github.com/TrustTunnel/TrustTunnelClient/releases/download/{tag}/{name}')])


class ClientUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.bin = self.path/'opt/trusttunnel/bin/trusttunnel_client'
        self.bin.parent.mkdir(parents=True)
        self.bin.write_bytes(b'old verified fixture'); self.bin.chmod(0o755)
        self.digest = hashlib.sha256(self.bin.read_bytes()).hexdigest()
        Path(str(self.bin)+'.sha256').write_text(self.digest)
        self.run = self.path/'tmp/trusttunnel'; self.run.mkdir(parents=True)
        (self.path/'proc/sys/kernel/random').mkdir(parents=True)
        (self.path/'proc/sys/kernel/random/boot_id').write_text('synthetic-boot-1')
        (self.path/'proc/uptime').write_text('1000.0 0.0\n')
        self.config = self.path/'jffs/addons/trusttunnel/config'; self.config.mkdir(parents=True)
        self.stage = self.bin.parent/'stage'; self.stage.write_bytes(b'new verified fixture'); self.stage.chmod(0o755)
        self.metadata = self.path/'installed.json'; self.metadata.write_text('{"version":"1.1.7"}')

    def shell(self, body):
        setup = '''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/client-update.sh"
timeout() { shift; "$@"; }
# No live commands in these tests: these overrides follow common.sh's PATH.
tt_update_guards() { return 0; }
tt_stop_process() { printf 'stop\n' >>"$TT_RUN/effects"; }
tt_spawn() { printf 'spawn\n' >>"$TT_RUN/effects"; }
'''
        return subprocess.run(['sh', '-c', setup+body], capture_output=True, text=True,
            env=os.environ | {'TT_ROOT':str(self.path), 'TT_BASE':str(ROOT/'addon')})

    def select(self, releases, channel):
        r = subprocess.run(['jq', '--arg', 'channel', channel, '-f', str(ROOT/'addon/share/client-releases.jq')],
                           input=json.dumps(releases), text=True, capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        return json.loads(r.stdout)

    def test_stable_ignores_newer_beta_and_nightly(self):
        rows=[release(),release('v1.3.0-beta.1',True,'2026-09-29'),release('v1.3.0-nightly.9',True,'2026-09-30')]
        self.assertEqual(self.select(rows,'stable')['tag'],'v1.1.7')
        self.assertEqual(self.select(rows,'nightly')['tag'],'v1.3.0-nightly.9')

    def test_nightly_never_falls_back_to_beta_or_stable(self):
        self.assertIsNone(self.select([release(),release('v1.3.0-beta.1',True)],'nightly'))

    def test_unsafe_url_digest_size_or_missing_asset_refused(self):
        for field,value in [('browser_download_url','https://evil.example/client'),('digest',None),('size',33554433),('name','other-linux-aarch64.tar.gz')]:
            with self.subTest(field=field):
                r=release(); r['assets'][0][field]=value
                self.assertIsNone(self.select([r],'stable'))

    def test_unknown_version_has_one_explicit_relation_instead_of_empty_json(self):
        r=subprocess.run(['jq','-n','-L',str(ROOT/'addon/share'),'include "versions"; "v1.1.7"|version_relation("unknown")'],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout),'unknown')

    def test_offline_commands_never_fetch_or_execute(self):
        for command in ['tt_update_check','tt_update_install 0123456789abcdef']:
            r=self.shell('curl() { echo HOST_CALL; }; timeout() { echo HOST_EXEC; }; '+command)
            self.assertNotEqual(r.returncode,0)
            self.assertNotIn('HOST_',r.stdout+r.stderr)

    def test_channel_persists_privately_invalidates_candidate_and_backs_up(self):
        (self.run/'client-candidate.json').write_text('{}')
        r=self.shell('tt_update_channel stable && tt_update_channel nightly && tt_update_get_channel')
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(r.stdout.strip(),'nightly')
        self.assertFalse((self.run/'client-candidate.json').exists())
        self.assertEqual(json.loads((self.config/'client-channel.json.previous').read_text())['channel'],'stable')
        self.assertEqual((self.config/'client-channel.json').stat().st_mode&0o777,0o600)

    def test_metadata_download_unlocks_controller_for_refresh(self):
        (self.path/'releases.json').write_text(json.dumps([release()]))
        # This exercises real host flock, including release of the shared parent
        # descriptor and reacquisition under tt_lock. Only fetch is a mock.
        r=self.shell('''tt_live() { return 0; }
tt_update_version() { printf 1.1.5; }
tt_update_fetch() {
    sh -c 'exec 8>"$1"; flock -n 8' sh "$TT_RUN/control.lock" 9>&- || return 1
    cp "$TT_ROOT/releases.json" "$2"
}
tt_lock && tt_update_check && tt_lock
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads((self.run/'client-candidate.json').read_text())['state'],'available')

    def test_last_check_survives_channel_change_and_runtime_loss(self):
        (self.path/'releases.json').write_text(json.dumps([release()]))
        r=self.shell('''tt_live() { return 0; }
tt_update_version() { printf 1.1.5; }
tt_update_fetch() { cp "$TT_ROOT/releases.json" "$2"; }
tt_lock && tt_update_check && tt_lock && tt_update_channel nightly
rm -f "$TT_RUN/client-candidate.json"
tt_update_status''')
        self.assertEqual(r.returncode,0,r.stderr)
        status=json.loads(r.stdout)
        self.assertIsNone(status['check'])
        self.assertEqual(status['channel'],'nightly')
        self.assertEqual(status['last_check']['channel'],'stable')
        self.assertEqual(status['last_check']['available_tag'],'v1.1.7')
        self.assertGreater(status['last_check']['checked_at'],0)
        self.assertEqual((self.config/'client-last-check.json').stat().st_mode&0o777,0o600)
        r=self.shell('tt_update_status')
        self.assertEqual(json.loads(r.stdout)['last_check'],status['last_check'])

    def test_last_check_write_refuses_symlink_and_failed_fetch_preserves_history(self):
        history=self.config/'client-last-check.json'
        history.write_text('{"checked_at":123,"channel":"stable"}')
        r=self.shell('tt_live() { return 0; }; tt_update_fetch() { return 99; }; tt_lock && tt_update_check')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(json.loads(history.read_text())['checked_at'],123)
        target=self.path/'foreign.json'; target.write_text('{}')
        history.unlink(); history.symlink_to(target)
        (self.path/'releases.json').write_text(json.dumps([release()]))
        r=self.shell('tt_live() { return 0; }; tt_update_version() { printf 1.1.5; }; tt_update_fetch() { cp "$TT_ROOT/releases.json" "$2"; }; tt_lock && tt_update_check')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(target.read_text(),'{}')
        self.assertFalse((self.run/'client-candidate.json').exists())

    def test_installer_declares_update_verification_dependencies(self):
        installer=(ROOT/'tools/setup-router.sh').read_text()
        preparer=(ROOT/'tools/prepare-entware.sh').read_text()
        self.assertIn('prepare-entware.sh',installer)
        for dependency in ('gnupg','coreutils-timeout','tar'):
            self.assertIn(dependency,preparer)
        for utility in ('gpg','timeout','tar'):
            self.assertIn(utility,installer.split('for utility in ',1)[1].split('; do',1)[0])
        for script in ('install.sh','tools/install-client.sh','tools/router-platform.sh'):
            self.assertIn('client-update-journal.json',(ROOT/script).read_text())
        self.assertIn('router-platform.sh',installer)
        self.assertIn('tt_install_platform "$FROM_IPK"',installer)

    def test_candidate_token_channel_and_ttl_are_bound(self):
        now=int(__import__('time').time())
        data=dict(id='0123456789abcdef',channel='stable',state='available',checked_at=now,candidate={},installed_sha256=self.digest)
        for patch,valid in [({},True),({'checked_at':now-3601},False),({'checked_at':now+60},False),({'channel':'nightly'},False),({'id':'f'*16},False),({'candidate':None},False),({'installed_sha256':'b'*64},False)]:
            (self.run/'client-candidate.json').write_text(json.dumps(data|patch))
            r=self.shell('tt_update_candidate_valid 0123456789abcdef')
            self.assertEqual(r.returncode==0,valid)

    def test_active_replace_preserves_enabled_intent_and_backups(self):
        (self.config/'enabled').touch()
        r=self.shell('tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.bin.read_bytes(),b'new verified fixture')
        self.assertEqual(Path(str(self.bin)+'.previous').read_bytes(),b'old verified fixture')
        self.assertTrue((self.config/'enabled').exists())
        self.assertEqual((self.run/'effects').read_text(),'stop\nspawn\n')
        self.assertEqual(json.loads((self.config/'client-update-journal.json').read_text())['phase'],'trial')
        installed=json.loads((self.config/'client-release.json').read_text())
        self.assertGreater(installed['installed_at'],0)

    def test_trial_survives_refresh_then_expires_on_monotonic_clock(self):
        (self.config/'enabled').touch()
        result=self.shell('''tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json" && tt_update_recover
printf '1500.0 0' >"$TT_PROC/uptime"
tt_update_recover''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')
        self.assertFalse((self.config/'client-update-journal.json').exists())

    def test_trial_confirm_requires_explicit_confirmation_and_bound_binary(self):
        (self.config/'enabled').touch()
        result=self.shell('''tt_live() { return 0; }; tt_pid_matches() { return 0; }; ip() { return 0; }
tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json" && tt_update_confirm''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.bin.read_bytes(),b'new verified fixture')
        self.assertFalse((self.config/'client-update-journal.json').exists())
        self.assertTrue(Path(str(self.bin)+'.previous').exists())

    def test_trial_reverts_conservatively_after_new_boot(self):
        (self.config/'enabled').touch()
        result=self.shell('''tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json" || exit 1
printf other-boot >"$TT_PROC/sys/kernel/random/boot_id"
tt_update_recover''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')

    def test_older_signed_candidate_requires_downgrade_mode(self):
        (self.path/'releases.json').write_text(json.dumps([release('v1.1.5')]))
        result=self.shell('''tt_live() { return 0; }; tt_update_version() { printf 1.1.7; }
tt_update_fetch() { cp "$TT_ROOT/releases.json" "$2"; }
tt_lock && tt_update_check && tt_lock || exit 1
id=$(jq -r .id "$TT_RUN/client-candidate.json")
! tt_update_candidate_valid "$id" && tt_update_candidate_valid "$id" downgrade''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.run/'client-candidate.json').read_text())['state'],'older')

    def test_explicit_rollback_after_acceptance_preserves_guards_and_resumes(self):
        (self.config/'enabled').touch()
        result=self.shell('''tt_live() { return 0; }; tt_pid_matches() { return 0; }; ip() { return 0; }; tt_preflight() { return 0; }
tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json" && tt_update_confirm && tt_update_rollback''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')
        self.assertTrue((self.config/'enabled').exists())
        self.assertEqual((self.run/'effects').read_text(),'stop\nspawn\nstop\nspawn\n')

    def test_direct_import_refuses_an_unconfirmed_client_trial(self):
        (self.config/'client-update-journal.json').write_text('{}')
        r=self.shell('tt_import endpoint "$TT_BASE/../examples/endpoint.example.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('finish or recover',r.stderr)
        self.assertFalse((self.config/'endpoint.json').exists())

    def test_paused_replace_never_resumes_traffic(self):
        (self.config/'enabled').touch(); (self.config/'paused').touch()
        r=self.shell('tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.run/'effects').read_text(),'stop\n')
        self.assertTrue((self.config/'paused').exists())

    def test_new_start_failure_restores_old_binary_and_metadata(self):
        (self.config/'enabled').touch()
        (self.config/'client-release.json').write_text('{"version":"1.1.5","installed_at":123}')
        r=self.shell('''tt_spawn() { grep -q old "$TT_BIN"; }
tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"''')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')
        self.assertEqual(Path(str(self.bin)+'.sha256').read_text().strip(),self.digest)
        self.assertEqual(json.loads((self.config/'client-release.json').read_text())['version'],'1.1.5')
        self.assertEqual(json.loads((self.config/'client-release.json').read_text())['installed_at'],123)
        self.assertTrue((self.config/'enabled').exists())

    def test_interrupted_metadata_commit_is_recoverable(self):
        r=self.shell('tt_atomic_json() { case "$2" in */client-release.json) return 99;; esac; cp "$1" "$2"; }; tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertTrue((self.config/'client-update-journal.json').exists())
        r=self.shell('tt_update_recover')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')
        self.assertFalse((self.config/'client-update-journal.json').exists())

    def test_changed_old_binary_refuses_replacement_before_stop(self):
        self.bin.write_bytes(b'unowned bytes')
        r=self.shell('tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.run/'effects').exists())

    def test_failed_journal_commit_never_stops_or_replaces_client(self):
        r=self.shell('tt_atomic_json() { return 99; }; tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.run/'effects').exists())
        self.assertFalse((self.config/'client-update-journal.json').exists())
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')

    def test_recovery_refuses_unknown_replacement_and_metadata_symlink(self):
        for target in ('binary','metadata','metadata_directory'):
            with self.subTest(target=target):
                r=self.shell('tt_atomic_json() { case "$2" in */client-release.json) return 99;; esac; cp "$1" "$2"; }; tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
                self.assertNotEqual(r.returncode,0)
                self.assertTrue((self.config/'client-update-journal.json').exists())
                if target=='binary': self.bin.write_bytes(b'unknown replacement')
                elif target=='metadata': (self.config/'client-release.json.previous').symlink_to(self.path/'unknown.json')
                else: (self.config/'client-release.json.previous').mkdir()
                (self.run/'effects').unlink()
                r=self.shell('tt_update_recover')
                self.assertNotEqual(r.returncode,0)
                self.assertFalse((self.run/'effects').exists())
                # Reset the fixture without involving recovery of unknown objects.
                self.bin.write_bytes(b'old verified fixture')
                Path(str(self.bin)+'.sha256').write_text(self.digest)
                (self.config/'client-update-journal.json').unlink()
                previous=self.config/'client-release.json.previous'
                if previous.is_dir(): previous.rmdir()
                else: previous.unlink(missing_ok=True)
                self.stage.write_bytes(b'new verified fixture')

    def test_backup_destination_directory_refuses_before_stop(self):
        Path(str(self.bin)+'.previous').mkdir()
        r=self.shell('tt_update_replace "${TT_BIN%/*}/stage" "$TT_ROOT/installed.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.run/'effects').exists())

    def test_changed_channel_during_unlocked_download_refuses_install(self):
        r=self.install_fixture('''tt_update_fetch() { case "$1" in *"/releases/1") cp "$TT_ROOT/upstream.json" "$2";; *) cp "$TT_ROOT/download.tar.gz" "$2"; printf '{"channel":"nightly"}' >"$TT_CONFIG/client-channel.json";; esac; }''')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.run/'effects').exists())
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')

    def test_archive_known_members_only_and_symlink_refusal(self):
        for symlink in [False,True]:
            archive=self.path/'archive.tar.gz'
            with tarfile.open(archive,'w:gz') as tar:
                for name,data in [('trusttunnel_client-v1.1.7-linux-aarch64/trusttunnel_client',b'new binary'),('trusttunnel_client-v1.1.7-linux-aarch64/trusttunnel_client.sig',b'signature'),('../outside',b'must not extract')]:
                    member=tarfile.TarInfo(name); member.size=len(data)
                    if symlink and name.endswith('/trusttunnel_client'):
                        member.type=tarfile.SYMTYPE; member.linkname='../outside'; member.size=0
                    tar.addfile(member,io.BytesIO(data) if member.isfile() else None)
            r=self.shell('tt_update_unpack "$TT_ROOT/archive.tar.gz" "$TT_ROOT/extracted" "$TT_RUN" trusttunnel_client-v1.1.7-linux-aarch64')
            self.assertEqual(r.returncode==0,not symlink,r.stderr)
            self.assertFalse((self.path.parent/'outside').exists())

    def test_archive_directory_is_bound_to_the_selected_version(self):
        archive=self.path/'archive.tar.gz'
        with tarfile.open(archive,'w:gz') as tar:
            for name in ('trusttunnel_client','trusttunnel_client.sig'):
                member=tarfile.TarInfo('trusttunnel_client-v1.1.7-linux-aarch64/'+name)
                member.size=7; tar.addfile(member,io.BytesIO(b'fixture'))
        for directory in ('trusttunnel_client-v1.1.8-linux-aarch64','../outside','trusttunnel_client'):
            r=self.shell('tt_update_unpack "$TT_ROOT/archive.tar.gz" "$TT_ROOT/extracted" "$TT_RUN" "'+directory+'"')
            self.assertNotEqual(r.returncode,0)
            self.assertFalse((self.path/'extracted').exists())

    def test_pinned_signature_and_elf_required_before_execute(self):
        binary=self.path/'elf'; binary.write_bytes(bytes.fromhex('7f454c460201')+b'\0'*12+bytes([183,0])+b'\0'*44)
        (self.path/'sig').touch()
        stub='''timeout() { shift; "$@"; }
gpg() { case " $* " in *" --import "*) return 0;; esac; printf '[GNUPG:] VALIDSIG %s\n' SIGNER; }
'''
        for signer,valid in [(SIGNER,True),('a'*40,False)]:
            r=self.shell(stub.replace('SIGNER',signer)+'tt_update_verify_binary "$TT_ROOT/elf" "$TT_ROOT/sig"')
            self.assertEqual(r.returncode==0,valid,r.stderr)
        binary.write_bytes(b'not ELF')
        r=self.shell(stub.replace('SIGNER',SIGNER)+'tt_update_verify_binary "$TT_ROOT/elf" "$TT_ROOT/sig"')
        self.assertNotEqual(r.returncode,0)

    def test_status_does_not_show_version_from_another_binary(self):
        (self.config/'client-release.json').write_text(json.dumps(dict(version='1.1.7',sha256=self.digest)))
        (self.run/'client-candidate.json').write_text(json.dumps(dict(installed_version='1.1.7',installed_sha256=self.digest)))
        r=self.shell('tt_update_status')
        self.assertEqual(json.loads(r.stdout)['installed']['version'],'1.1.7')
        Path(str(self.bin)+'.sha256').write_text('b'*64)
        r=self.shell('tt_update_status')
        self.assertIsNone(json.loads(r.stdout)['installed'])
        self.assertIsNone(json.loads(r.stdout)['check'])

    def test_controller_loads_update_and_traffic_status_modules(self):
        (self.config/'client-channel.json').write_text('{"channel":"nightly"}')
        r=subprocess.run([str(ROOT/'addon/trusttunnel.sh'),'status'],capture_output=True,text=True,
            env=os.environ|{'TT_ROOT':str(self.path)})
        self.assertEqual(r.returncode,0,r.stderr)
        report=json.loads(r.stdout)
        self.assertEqual(report['client_updates']['channel'],'nightly')
        self.assertIn('dependencies_ready',report['client_updates'])
        self.assertEqual(report['tunnel_addresses'],[])
        self.assertIsNone(report['traffic_check'])

    def install_fixture(self, mutation=''):
        archive=self.path/'download.tar.gz'
        elf=bytes.fromhex('7f454c460201')+b'\0'*12+bytes([183,0])+b'\0'*44
        with tarfile.open(archive,'w:gz') as tar:
            for name,data in [('trusttunnel_client-v1.1.7-linux-aarch64/trusttunnel_client',elf),('trusttunnel_client-v1.1.7-linux-aarch64/trusttunnel_client.sig',b'fixture signature')]:
                member=tarfile.TarInfo(name); member.size=len(data); tar.addfile(member,io.BytesIO(data))
        upstream=release(); upstream['assets'][0]['digest']='sha256:'+hashlib.sha256(archive.read_bytes()).hexdigest()
        upstream['assets'][0]['size']=archive.stat().st_size
        (self.path/'upstream.json').write_text(json.dumps(upstream))
        selected=self.select([upstream],'stable')
        (self.run/'client-candidate.json').write_text(json.dumps(dict(id='0123456789abcdef',channel='stable',state='available',
            checked_at=int(__import__('time').time()),candidate=selected,installed_sha256=self.digest)))
        script='''tt_live() { return 0; }
flock() { return 0; }
tt_lock() { return 0; }
uname() { printf aarch64; }
tt_update_fetch() { case "$1" in *"/releases/1") cp "$TT_ROOT/upstream.json" "$2";; *) cp "$TT_ROOT/download.tar.gz" "$2";; esac; }
timeout() { shift; case "$1" in *".next."*) printf 'trusttunnel_client 1.1.7\n';; *) "$@";; esac; }
gpg() { case " $* " in *" --import "*) return 0;; esac; printf '[GNUPG:] VALIDSIG 28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6\n'; }
'''
        return self.shell(script+mutation+'\ntt_update_install 0123456789abcdef')

    def test_full_mock_download_verify_and_atomic_install(self):
        r=self.install_fixture()
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads((self.config/'client-release.json').read_text())['version'],'1.1.7')
        self.assertTrue(self.bin.read_bytes().startswith(b'\x7fELF'))
        self.assertEqual(Path(str(self.bin)+'.previous').read_bytes(),b'old verified fixture')

    def test_mutable_release_recheck_refuses_changed_metadata(self):
        r=self.install_fixture('jq \' .assets[0].digest="sha256:"+("b"*64) \' "$TT_ROOT/upstream.json" >"$TT_RUN/replaced"; mv "$TT_RUN/replaced" "$TT_ROOT/upstream.json"')
        self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.run/'effects').exists())
        self.assertEqual(self.bin.read_bytes(),b'old verified fixture')

    def test_digest_signature_or_version_mismatch_never_stops_old_client(self):
        for mutation in ['printf tampered >"$TT_ROOT/download.tar.gz"',
            'gpg() { return 1; }',
            'timeout() { shift; case "$1" in *".next."*) printf "1.0.0";; *) "$@";; esac; }']:
            with self.subTest(mutation=mutation):
                r=self.install_fixture(mutation)
                self.assertNotEqual(r.returncode,0)
                self.assertFalse((self.run/'effects').exists())
                self.assertEqual(self.bin.read_bytes(),b'old verified fixture')

    def test_bundled_public_key_has_pinned_fingerprint(self):
        lines=(ROOT/'addon/share/client-release-key.asc').read_text().splitlines()
        body=''.join(line for line in lines if line and not line.startswith(('-----','Comment:','=')))
        packet=base64.b64decode(body)
        self.assertEqual(packet[0]&63,6)  # new-format public-key packet
        length=((packet[1]-192)<<8)+packet[2]+192 if packet[1]<224 else int.from_bytes(packet[2:6],'big')
        offset=3 if packet[1]<224 else 6
        key=packet[offset:offset+length]
        self.assertEqual(hashlib.sha1(b'\x99'+len(key).to_bytes(2,'big')+key).hexdigest().upper(),SIGNER)
