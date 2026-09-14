"""Regression cases for parser ambiguity and the manual/SSH endpoint boundary."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EP = json.loads((ROOT/'examples/endpoint.example.json').read_text())

class ValidationBoundaries(unittest.TestCase):
    def validate(self, text):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/'fixture.json'
            source.write_text(text)
            return subprocess.run([str(ROOT/'addon/trusttunnel.sh'),'validate','endpoint',str(source)],capture_output=True,text=True)

    def test_rejects_concatenated_json_instead_of_accepting_last(self):
        for first in ('null', '{}', json.dumps(EP)):
            self.assertNotEqual(self.validate(first+'\n'+json.dumps(EP)).returncode,0)

    def test_invalid_hostnames_and_ipv4_are_rejected_from_ssh(self):
        for hostname in ('bad..host','-bad.example','bad-.example','256.1.1.1','01.2.3.4','a'*64+'.example','bad.example.'):
            with self.subTest(hostname=hostname):
                value=dict(EP,hostname=hostname)
                self.assertNotEqual(self.validate(json.dumps(value)).returncode,0)
                value=dict(EP,addresses=[hostname+':443'])
                self.assertNotEqual(self.validate(json.dumps(value)).returncode,0)

    def test_errors_do_not_echo_values_from_malformed_multiple_json(self):
        marker='SYNTHETIC_SECRET_MUST_NOT_BE_PRINTED'
        result=self.validate('{"password":"'+marker+'" broken}\n'+json.dumps(EP))
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn(marker,result.stdout+result.stderr)

if __name__=='__main__': unittest.main()
