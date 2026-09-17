"""Offline recovery must not turn an uncertain send into a repeated IR command."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tuya-local/commissioning'))
from resume_korean_export import inspect_journal, cooldown_until

class ResumePolicyTests(unittest.TestCase):
    def inspect(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'journal.jsonl'
            path.write_text('\n'.join(json.dumps(x) for x in rows))
            return inspect_journal(path)

    def test_offline_rejection_is_not_uncertain_and_requires_cooldown(self):
        result={'job':0,'phase':'result','accepted':False,'error_code':30003,'end_ms':100000}
        count,last=self.inspect([{'job':0,'phase':'start'},result])
        self.assertEqual(count,1)
        self.assertEqual(cooldown_until(last,110),1000)

    def test_missing_response_must_not_resume(self):
        with self.assertRaisesRegex(ValueError,'Uncertain'):
            self.inspect([{'job':0,'phase':'start'}])

    def test_other_rejection_must_not_resume(self):
        with self.assertRaisesRegex(ValueError,'Non-offline'):
            self.inspect([{'job':0,'phase':'start'},{'job':0,'phase':'result','accepted':False,'error_code':30100}])

    def test_duplicate_phase_must_not_resume(self):
        with self.assertRaisesRegex(ValueError,'Duplicate'):
            self.inspect([{'job':0,'phase':'start'}]*2)

    def test_success_can_continue_without_replaying_old_job(self):
        count,last=self.inspect([{'job':0,'phase':'start'},{'job':0,'phase':'result','accepted':True}])
        self.assertEqual(count,1)
        self.assertEqual(cooldown_until(last,100),100)

if __name__=='__main__':unittest.main()
