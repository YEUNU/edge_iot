"""Commissioning routing tests; never contact Tuya or send physical IR."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tuya-local/commissioning'))
from export_korean_brands import request_for

class ExportTests(unittest.TestCase):
    def request(self, key, key_id=0):
        return request_for({'remote_index': 123, 'key': key, 'key_id': key_id})

    def test_temperature_and_fan_use_ac_api_not_zero_raw_key(self):
        endpoint, body = self.request('M1_T28_S3')
        self.assertEqual(endpoint, 'air-conditioners/testing/scenes/command')
        self.assertEqual(body, dict(remote_index=123, category_id=5, power=1, mode=1, temp=28, wind=3))
        self.assertNotIn('key_id', body)

    def test_fixed_temperature_and_fan_states(self):
        self.assertNotIn('temp', self.request('M3_S2')[1])
        self.assertNotIn('wind', self.request('M2_T17')[1])
        self.assertEqual(self.request('power_off')[1]['power'], 0)
        self.assertEqual(self.request('power_on')[1]['power'], 1)

    def test_extra_key_requires_real_id(self):
        self.assertEqual(self.request('swing', 17), ('testing/raw/command',
                         dict(remote_index=123, category_id=5, key='swing', key_id=17)))
        with self.assertRaises(ValueError): self.request('swing')


from join_korean_logs import join
class LogJoinTests(unittest.TestCase):
    def test_success_without_publish_is_not_capture(self):
        journal = [{'job': 0, 'phase': 'start'},
                   {'job': 0, 'phase': 'result', 'accepted': True, 'response_ms': 1000}]
        result = join(journal, [], timezone='UTC')
        self.assertEqual(result['captured'], [])
        self.assertEqual(len(result['missing']), 1)

    def test_ambiguous_publish_is_not_capture(self):
        journal = [{'job': 0, 'phase': 'start'},
                   {'job': 0, 'phase': 'result', 'accepted': True, 'response_ms': 1000}]
        rows = [{'time': '1970-01-01 00:00:01', 'command':
                 {'control': 'send_ir', 'type': 0, 'head': 'h', 'key1': k}} for k in ['a', 'b']]
        self.assertFalse(join(journal, rows, timezone='UTC')['captured'])

    def test_exact_payload_preserved(self):
        journal = [{'job': 0, 'phase': 'start', 'remote_index': 123, 'key': 'M0_T25_S0'},
                   {'job': 0, 'phase': 'result', 'accepted': True, 'response_ms': 1000}]
        command = {'control': 'send_ir', 'type': 0, 'head': 'h', 'key1': 'a'}
        rows = [{'time': '1970-01-01 00:00:01', 'command': command}]
        result = join(journal, rows, timezone='UTC')
        self.assertEqual(result['captured'][0]['command'], command)
        self.assertFalse(result['missing'])

from build_korean_catalog import profile
class CatalogBuildTests(unittest.TestCase):
    def row(self, key):
        return {'key':key,'brands':['LG','Samsung'], 'command':
                {'control':'send_ir','type':0,'head':'head','key1':key}}

    def test_all_original_keys_retained_and_shared_brands_preserved(self):
        result = profile(123, [self.row('power_off'), self.row('M0_T25_S0'), self.row('power_on')])
        self.assertEqual(result['control_style'], 'state')
        self.assertEqual(len(result['keys']), 3)
        self.assertEqual(len(result['codes']), 2)
        self.assertEqual(result['brands'], ['LG','Samsung'])
        self.assertEqual(result['default_state']['target_temperature'], 25)

    def test_toggle_remote_is_buttons_only(self):
        result = profile(123, [self.row('power'), self.row('temperature_up')])
        self.assertEqual(result['control_style'], 'buttons')
        self.assertEqual(result['codes'], [])
        self.assertEqual(result['default_state'], {})

    def test_conflicting_absolute_states_remain_distinct_buttons(self):
        result = profile(123, [self.row('power_off'), self.row('M2_S0'), self.row('M2_T25_S0')])
        self.assertEqual(result['control_style'], 'buttons')
        self.assertEqual(len(result['keys']), 3)

class PublishWindowTests(unittest.TestCase):
    def test_publish_before_response_second_is_retained(self):
        journal = [{'job':0,'phase':'start','start_ms':1500},
                   {'job':0,'phase':'result','accepted':True,'response_ms':2020,'end_ms':2100}]
        rows = [{'time':'1970-01-01 00:00:01','command':{'control':'send_ir','type':0,'head':'h','key1':'k'}}]
        self.assertEqual(len(join(journal,rows,'UTC')['captured']),1)

    def test_shared_second_is_not_assigned_by_guess(self):
        journal = [{'job':0,'phase':'start','start_ms':1500},
                   {'job':0,'phase':'result','accepted':True,'response_ms':2020,'end_ms':2100},
                   {'job':1,'phase':'start','start_ms':2900},
                   {'job':1,'phase':'result','accepted':True,'response_ms':3500,'end_ms':3600}]
        rows = [{'time':'1970-01-01 00:00:02','command':{'control':'send_ir','type':0,'head':'h','key1':'k'}}]
        self.assertFalse(join(journal,rows,'UTC')['captured'])

from join_korean_logs import merge_results
class RecaptureMergeTests(unittest.TestCase):
    def test_successful_recapture_resolves_only_its_gap(self):
        original={'captured':[],'missing':[{'job':1,'reason':'missing'},{'job':2,'reason':'missing'}]}
        retry={'captured':[{'job':1,'key':'power','command':{'key1':'a'}}],'missing':[]}
        result=merge_results([original,retry])
        self.assertEqual([x['job'] for x in result['captured']],[1])
        self.assertEqual([x['job'] for x in result['missing']],[2])

    def test_conflicting_captures_fail_closed(self):
        a={'captured':[{'job':1,'key':'power','command':{'key1':'a'}}],'missing':[]}
        b={'captured':[{'job':1,'key':'power','command':{'key1':'b'}}],'missing':[]}
        result=merge_results([a,b])
        self.assertFalse(result['captured'])
        self.assertEqual(result['missing'][0]['reason'],'conflicting_captures')

from verify_korean_release import verify
import gzip
import json
import tempfile

class ReleaseCoverageTests(unittest.TestCase):
    def test_release_requires_every_key_and_brand_alias(self):
        scope={'keys_by_remote':{'123':['power','mode']},'unique_indexes':1,'expected_keys':2,
               'brands':[{'name':name,'remote_indexes':[123]} for name in ('LG','Samsung')]}
        payload={'control':'send_ir','type':0,'head':'h','key1':'k','key2':'second-frame'}
        data={'remote_index':123,'brands':['LG','Samsung'],'keys':[{'id':key,'command':payload} for key in ('power','mode')]}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'index.json').write_text(json.dumps({'profiles':[{'remote_index':123,'manufacturer':'LG','brands':['LG','Samsung']}]}))
            def save():
                (root/'123.json.gz').write_bytes(gzip.compress(json.dumps(data).encode()))
            save()
            self.assertEqual(verify(root,scope),{'remote_indexes':1,'keys':2})
            metadata=json.loads((root/'index.json').read_text())
            metadata['profiles'][0]['brands']=['LG']
            (root/'index.json').write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError,'index brand aliases'):
                verify(root,scope)
            metadata['profiles'][0]['brands']=['LG','Samsung']
            (root/'index.json').write_text(json.dumps(metadata))
            stale=root/'999.json.gz'
            stale.write_bytes(gzip.compress(b'{}'))
            with self.assertRaisesRegex(ValueError,'files and index'):
                verify(root,scope)
            stale.unlink()
            with self.assertRaisesRegex(ValueError,'Existing working'):
                verify(root,scope,require_existing=True)
            data['keys'].pop();save()
            with self.assertRaisesRegex(ValueError,'keys'):
                verify(root,scope)
            data['keys'].append({'id':'mode','command':payload})
            data['brands']=['LG'];save()
            with self.assertRaisesRegex(ValueError,'aliases'):
                verify(root,scope)
            data['brands']=['LG','Samsung'];save()
            (root/'index.json').write_text(json.dumps({'profiles':[{'remote_index':123},{'remote_index':999}]}))
            with self.assertRaisesRegex(ValueError,'out-of-scope'):
                verify(root,scope)

if __name__ == '__main__':
    unittest.main()
