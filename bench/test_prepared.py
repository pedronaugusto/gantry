"""Preparation rejection and artifact checks; only temporary files, no timings."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from prepared import Prepared
from quiet_common import Pass

class PreparedTests(unittest.TestCase):
    def test_missing_and_changed_artifacts_fail_before_measurement(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            prepared = Prepared(root, root)
            with patch.object(prepared, 'identity', return_value='source'):
                with self.assertRaises(RuntimeError): prepared.check()
                binary = root/'binary'
                binary.write_bytes(b'compiled')
                prepared.require(binary)
                prepared.write()
                prepared.check()
                binary.write_bytes(b'changed')
                with self.assertRaises(RuntimeError): prepared.check()
                binary.unlink()
                with self.assertRaises(RuntimeError): prepared.check()

    def test_source_change_rejects_preparation(self):
        with tempfile.TemporaryDirectory() as name:
            prepared = Prepared(Path(name), Path(name))
            with patch.object(prepared, 'identity', return_value='old'): prepared.write()
            with patch.object(prepared, 'identity', return_value='new'):
                with self.assertRaises(RuntimeError): prepared.check()

    def test_preparation_never_writes_over_a_pass_report(self):
        with tempfile.TemporaryDirectory() as name:
            out = Path(name)
            (out/'report.json').write_text('real pass')
            (out/'report.md').write_text('real pass')
            run = Pass.__new__(Pass)
            run.smoke, run.plan_only, run.complete, run.out = False, True, True, out
            run.revisions, run.metadata, run.machine, run.rows = {'before':'a','after':'b'}, {}, {}, []
            with patch.object(Pass, 'git', return_value=''), patch.object(Pass, 'clean', side_effect=lambda value: value):
                run.save()
            self.assertEqual((out/'report.json').read_text(), 'real pass')
            self.assertEqual((out/'report.md').read_text(), 'real pass')
            self.assertTrue((out/'prepared.json').exists())

if __name__ == '__main__': unittest.main()
