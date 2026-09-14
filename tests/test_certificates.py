from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = (ROOT / "tests/fixtures/test-cert.crt").read_text()
BAD_DER = "-----BEGIN CERTIFICATE-----\nMAMBAgM=\n-----END CERTIFICATE-----\n"


class CertificateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = os.environ | {"TT_ROOT": str(self.path / "sandbox"), "TT_BASE": str(ROOT / "addon"), "TMPDIR": str(self.path)}

    def config(self, certificate):
        data = json.loads((ROOT / "examples/endpoint.example.json").read_text())
        data.update(certificate=certificate, password="CERT-TEST-PRIVATE-PASSWORD")
        file = self.path / "endpoint.json"; file.write_text(json.dumps(data)); return file

    def validate(self, certificate, body='tt_validate endpoint "$1"'):
        file = self.config(certificate)
        script = '. "$TT_BASE/lib/common.sh"\n. "$TT_BASE/lib/config.sh"\n' + body
        result = subprocess.run(["sh", "-c", script, "certificate-test", str(file)], env=self.env, text=True, capture_output=True)
        self.assertNotIn("CERT-TEST-PRIVATE-PASSWORD", result.stderr + result.stdout)
        self.assertEqual(list(self.path.glob("ttm-cert.*")), [], "private certificate staging was not removed")
        return result

    def no_openssl(self, certificate):
        fake = self.path / "without-openssl"; fake.mkdir()
        for command in ("jq", "wc"):
            (fake / command).symlink_to(shutil.which(command))
        self.env["TT_TEST_PATH"] = str(fake)
        return self.validate(certificate, 'PATH="$TT_TEST_PATH"\nexport PATH\ntt_validate endpoint "$1"')

    def test_empty_certificate_does_not_require_openssl(self):
        result = self.no_openssl("")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_certificate_requires_openssl(self):
        result = self.no_openssl(CERTIFICATE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("openssl is required", result.stderr)

    def test_valid_certificate_and_crlf_bundle(self):
        for certificate in (CERTIFICATE, CERTIFICATE.replace("\n", "\r\n"), CERTIFICATE + CERTIFICATE):
            with self.subTest(length=len(certificate)):
                result = self.validate(certificate)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_framed_base64_that_is_not_x509_is_rejected(self):
        result = self.validate(BAD_DER)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid X509", result.stderr)
        self.assertNotIn("MAMBAgM", result.stderr + result.stdout)

    def test_valid_first_certificate_does_not_hide_corrupt_second(self):
        result = self.validate(CERTIFICATE + BAD_DER)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid X509", result.stderr)

    def test_text_outside_or_incomplete_blocks_is_rejected(self):
        cases = ["EXTERNAL-SECRET-TEXT\n" + CERTIFICATE, CERTIFICATE + "EXTERNAL-SECRET-TEXT\n",
                 CERTIFICATE.replace("-----END CERTIFICATE-----", ""),
                 "-----BEGIN CERTIFICATE-----\n" + CERTIFICATE,
                 CERTIFICATE + "-----END CERTIFICATE-----\n",
                 CERTIFICATE.replace("CERTIFICATE", "PRIVATE KEY")]
        for certificate in cases:
            with self.subTest(length=len(certificate)):
                result = self.validate(certificate)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("EXTERNAL-SECRET-TEXT", result.stderr + result.stdout)

    def test_temporary_files_are_private_and_openssl_receives_only_paths(self):
        probe = self.path / "probe.json"
        self.env["TT_CERT_PROBE"] = str(probe)
        self.env["TT_CERT_PYTHON"] = shutil.which("python3")
        script = self.path / "probe.py"
        script.write_text('''import json,os,stat,sys
from pathlib import Path
args=sys.argv[1:]
file=Path(args[args.index('-in')+1])
Path(os.environ['TT_CERT_PROBE']).write_text(json.dumps({'args':args,'file_mode':stat.S_IMODE(file.stat().st_mode),'dir_mode':stat.S_IMODE(file.parent.stat().st_mode)}))
''')
        self.env["TT_CERT_PROBE_SCRIPT"] = str(script)
        result = self.validate(CERTIFICATE, '''openssl() { "$TT_CERT_PYTHON" "$TT_CERT_PROBE_SCRIPT" "$@"; }
tt_validate endpoint "$1"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(probe.read_text())
        self.assertEqual(record["file_mode"], 0o600)
        self.assertEqual(record["dir_mode"], 0o700)
        self.assertEqual(record["args"][:3], ["x509", "-noout", "-in"])
        self.assertEqual(len(record["args"]), 4)
        self.assertNotIn("BEGIN CERTIFICATE", " ".join(record["args"]))


if __name__ == "__main__":
    unittest.main()
