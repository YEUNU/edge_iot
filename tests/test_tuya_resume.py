"""Offline recovery must not turn an uncertain send into a repeated IR command."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tuya-local/commissioning'))
from resume_korean_export import inspect_journal, cooldown_until
from export_korean_brands import read_request_journal

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

    def test_invalid_job_identity_and_acceptance_cannot_count_as_completion(self):
        for number, accepted in [(99, True), (True, True), (-1, True), (0, 'false'), (0, 1), (0, None)]:
            with self.subTest(number=number, accepted=accepted), self.assertRaises(ValueError):
                self.inspect([{'job':number,'phase':'start'},
                              {'job':number,'phase':'result','accepted':accepted}])

    def test_result_before_request_cannot_resume(self):
        with self.assertRaisesRegex(ValueError,'preceding'):
            self.inspect([{'job':0,'phase':'result','accepted':True},{'job':0,'phase':'start'}])

    def test_offline_rejection_requires_usable_timestamp(self):
        for stamp in (None, True, '1000', -1, 1.2, 10**1000):
            with self.subTest(stamp=stamp), self.assertRaisesRegex(ValueError,'timestamp'):
                self.inspect([{'job':0,'phase':'start'}, {'job':0,'phase':'result',
                    'accepted':False,'error_code':30003,'end_ms':stamp}])

    def test_current_plan_must_match_before_skip_or_recapture(self):
        jobs=[{'remote_index':123,'brands':['LG'],'key':'power_off','key_id':0,'key_name':'Off'},
              {'remote_index':456,'brands':['Samsung'],'key':'M0_T25_S0','key_id':0,'key_name':'Cool'}]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'journal.jsonl'
            def write(number, job):
                path.write_text('\n'.join(json.dumps(row) for row in [dict(job, job=number, phase='start'),
                    {'job':number,'phase':'result','accepted':True}]))
            write(0,jobs[0])
            self.assertEqual(inspect_journal(path,jobs)[0],1)
            for mutation in ({'remote_index':999}, {'key':'power_on'}, {'key_id':1},
                             {'brands':['Carrier']}, {'key_name':'Other'}):
                write(0,dict(jobs[0],**mutation))
                with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError,'plan mismatch'):
                    inspect_journal(path,jobs)
            # Recapture requests use original, sparse job numbers; identity still matters.
            write(1,jobs[1])
            starts, results=read_request_journal(path,jobs,contiguous=False)
            self.assertEqual(set(starts),{1})
            self.assertEqual(set(results),{1})
            with self.assertRaisesRegex(ValueError,'Noncontiguous'):
                inspect_journal(path,jobs)
            write(1,jobs[0])
            with self.assertRaisesRegex(ValueError,'plan mismatch'):
                read_request_journal(path,jobs,contiguous=False)

    def test_recapture_also_rejects_duplicate_or_uncertain_requests(self):
        jobs=[{'remote_index':123,'key':'power'}]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'journal.jsonl'
            start=dict(jobs[0],job=0,phase='start')
            result={'job':0,'phase':'result','accepted':True}
            for rows, message in [([start,start,result],'Duplicate'), ([start],'Uncertain')]:
                path.write_text('\n'.join(map(json.dumps,rows)))
                with self.subTest(rows=rows), self.assertRaisesRegex(ValueError,message):
                    read_request_journal(path,jobs,contiguous=False)

if __name__=='__main__':unittest.main()
