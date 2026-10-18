import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExclusionUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.config = self.path/'jffs/addons/trusttunnel/config'
        self.config.mkdir(parents=True)
        self.endpoint = json.loads((ROOT/'examples/endpoint.example.json').read_text())
        self.endpoint.update(password='SYNTHETIC-secret', username='SYNTHETIC-user',
                             certificate=(ROOT/'tests/fixtures/test-cert.crt').read_text())
        self.dest = self.config/'endpoint.json'
        self.dest.write_text(json.dumps(self.endpoint)); self.dest.chmod(0o600)
        self.original = self.dest.read_bytes()
        self.request = self.path/'request.json'

    def execute(self, data, before='', revision='0', kind='exclusions'):
        self.request.write_text(json.dumps(dict(version=1, kind=kind, revision=revision, data=data)))
        script = '''. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/service.sh"
tt_dirs && tt_lock || exit 90
'''+before+'\ntt_apply_request 0123456789abcdef "$TT_ROOT/request.json"'
        result = subprocess.run(['busybox','ash','-c',script], capture_output=True, text=True,
            env=os.environ|{'TT_ROOT':str(self.path),'TT_BASE':str(ROOT/'addon')})
        self.assertNotIn('SYNTHETIC-secret',result.stdout+result.stderr)
        return result

    def test_update_preserves_credentials_dns_certificate_and_private_backup(self):
        rules = ['example.com', '198.51.100.0/24']
        result = self.execute({'exclusions':rules})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.dest.read_text()),self.endpoint|{'exclusions':rules})
        backup = self.config/'endpoint.json.previous'
        self.assertEqual(backup.read_bytes(),self.original)
        for p in (self.dest,backup): self.assertEqual(p.stat().st_mode & 0o777,0o600)
        op = json.loads((self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').read_text())
        self.assertEqual((op['action'],op['state']),('exclusions','succeeded'))

    def test_empty_list_removes_all_rules(self):
        self.dest.write_text(json.dumps(self.endpoint|{'exclusions':['example.com']}))
        result = self.execute({'exclusions':[]})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.dest.read_text()),self.endpoint)

    def test_legacy_endpoint_without_exclusions(self):
        old = dict(self.endpoint); del old['exclusions']; self.dest.write_text(json.dumps(old))
        result = self.execute({'exclusions':['example.com']})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.dest.read_text()),self.endpoint|{'exclusions':['example.com']})

    def test_rejects_invalid_rules_extra_fields_and_wrong_types(self):
        for data in ({'exclusions':['https://example.com/path']},{'exclusions':[], 'password':'injected'},
                     {'exclusions':'example.com'}, {'exclusions':[None]}, {},
                     {'exclusions':['example.com','EXAMPLE.COM']}):
            with self.subTest(data=data):
                op = self.path/'tmp/trusttunnel/operations/0123456789abcdef.json'
                op.unlink(missing_ok=True)
                self.assertNotEqual(self.execute(data).returncode,0)
                self.assertEqual(self.dest.read_bytes(),self.original)
                self.assertFalse((self.config/'endpoint.json.previous').exists())

    def test_stale_revision_preserves_config(self):
        self.assertNotEqual(self.execute({'exclusions':[]},revision='stale').returncode,0)
        self.assertEqual(self.dest.read_bytes(),self.original)

    def test_missing_endpoint_cannot_be_created_by_partial_update(self):
        self.dest.unlink()
        self.assertNotEqual(self.execute({'exclusions':[]}).returncode,0)
        self.assertFalse(self.dest.exists())

    def test_pending_transaction_refuses_update(self):
        self.assertNotEqual(self.execute({'exclusions':[]},'mkdir "$TT_CONFIG/transaction"').returncode,0)
        self.assertEqual(self.dest.read_bytes(),self.original)

    def test_enabled_update_uses_endpoint_transaction_not_direct_writer(self):
        result = self.execute({'exclusions':['example.com']},'''touch "$TT_ENABLED"
tt_transaction_apply() { printf '%s' "$1" >"$TT_RUN/transaction-kind"; cp "$2" "$TT_RUN/transaction-data"; }
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.path/'tmp/trusttunnel/transaction-kind').read_text(),'endpoint')
        self.assertEqual(json.loads((self.path/'tmp/trusttunnel/transaction-data').read_text()),self.endpoint|{'exclusions':['example.com']})
        self.assertEqual(self.dest.read_bytes(),self.original)

    def test_partial_settings_preserve_dns_credentials_and_certificate(self):
        patch=dict(protocol='http3',mtu=1400,anti_dpi=True)
        result=self.execute(patch,kind='endpoint_settings')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.dest.read_text()),self.endpoint|patch)
        self.assertEqual((self.config/'endpoint.json.previous').read_bytes(),self.original)

    def test_partial_settings_cannot_modify_credentials_dns_or_unknown_fields(self):
        for patch in (dict(protocol='http3',mtu=1400,anti_dpi=True,password='injected'),
                      dict(protocol='http3',mtu=1400,anti_dpi=True,dns_upstreams=[]),
                      dict(protocol='http3',mtu=500,anti_dpi=True), {}):
            with self.subTest(patch=patch):
                (self.path/'tmp/trusttunnel/operations/0123456789abcdef.json').unlink(missing_ok=True)
                self.assertNotEqual(self.execute(patch,kind='endpoint_settings').returncode,0)
                self.assertEqual(self.dest.read_bytes(),self.original)

    def test_status_returns_only_exclusions_and_configured_flag(self):
        result = self.execute({'exclusions':['example.com']}, '''tt_status >"$TT_RUN/status-test.json"''')
        self.assertEqual(result.returncode,0,result.stderr)
        raw = (self.path/'tmp/trusttunnel/status-test.json').read_text()
        self.assertEqual(json.loads(raw)['endpoint'],dict(configured=True,exclusions=[],settings={key:self.endpoint[key] for key in ('protocol','mtu','anti_dpi')}))
        for secret in ('SYNTHETIC-secret','SYNTHETIC-user','BEGIN CERTIFICATE','tls://1.1.1.1'):
            self.assertNotIn(secret,raw)
