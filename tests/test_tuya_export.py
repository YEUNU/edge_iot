"""Commissioning routing tests; never contact Tuya or send physical IR."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tuya-local/commissioning'))
from export_korean_brands import request_for

class ExportTests(unittest.TestCase):
    def test_negative_limit_is_rejected_before_reading_data_or_sending(self):
        from unittest.mock import patch
        import export_korean_brands
        import recapture_korean_gaps
        import contextlib
        import io
        for module in (export_korean_brands,recapture_korean_gaps):
            with self.subTest(module=module.__name__), \
                 patch.object(sys,'argv',[module.__name__,'--data','unused','--send','--hub-covered','--limit','-1']), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:module.main()
                self.assertEqual(error.exception.code,2)

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
    def test_boolean_or_float_raw_type_cannot_be_captured_as_integer_zero(self):
        journal=[{'job':0,'phase':'start'},
                 {'job':0,'phase':'result','accepted':True,'response_ms':1000}]
        for value in (False,0.0):
            rows=[{'time':'1970-01-01 00:00:01','command':
                   {'control':'send_ir','type':value,'head':'h','key1':'k'}}]
            with self.subTest(value=value):
                result=join(journal,rows,'UTC')
                self.assertFalse(result['captured'])
                self.assertEqual(result['missing'][0]['reason'],'unsupported_payload')

    def test_malformed_acceptance_and_unknown_phase_cannot_capture_ir(self):
        start={'job':0,'phase':'start'}
        rows=[{'time':'1970-01-01 00:00:01','command':
               {'control':'send_ir','type':0,'head':'h','key1':'k'}}]
        for response in ({'job':0,'phase':'result','accepted':'false','response_ms':1000},
                         {'job':0,'phase':'other','accepted':True,'response_ms':1000}):
            with self.subTest(response=response), self.assertRaises(ValueError):
                join([start,response],rows,'UTC')

    def test_result_before_request_cannot_be_used_as_capture_evidence(self):
        with self.assertRaisesRegex(ValueError,'preceding'):
            join([{'job':0,'phase':'result','accepted':True,'response_ms':1000},
                  {'job':0,'phase':'start','key':'power_off'}],[], 'UTC')

    def test_uncertain_request_remains_explicit_gap(self):
        self.assertEqual(join([{'job':0,'phase':'start'}],[],'UTC'),
                         {'captured':[],'missing':[{'job':0,'reason':'unaccepted_or_uncertain'}]})

    def test_join_cli_validates_plan_for_primary_and_recapture(self):
        from unittest.mock import patch
        import join_korean_logs as module
        job={'remote_index':123,'brands':['LG'],'key':'power_off','key_id':0,'key_name':'Off'}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            primary=root/'korean-export-requests.jsonl'
            primary.write_text(json.dumps(dict(job,job=0,phase='start')))
            argv=['join_korean_logs.py','--data',str(root)]
            with patch.object(module,'plan',return_value=([],[job])), patch.object(sys,'argv',argv), patch('builtins.print'):
                module.main()
                report=json.loads((root/'korean-captured.json').read_text())
                self.assertEqual(len(report['missing']),1)
                (root/'korean-captured.json').unlink()
                for path in (primary, root/'korean-recapture-1.jsonl'):
                    path.write_text(json.dumps(dict(job,job=0,phase='start',key='power_on')))
                    with self.subTest(path=path), self.assertRaisesRegex(ValueError,'plan mismatch'):
                        module.main()
                    self.assertFalse((root/'korean-captured.json').exists())
                    path.write_text(json.dumps(dict(job,job=0,phase='start')))

    def test_malformed_timestamps_and_noncommand_rows_remain_gaps(self):
        command={'control':'send_ir','type':0,'head':'h','key1':'k'}
        for stamp in (True,'1000',float('nan'),float('inf'),10**1000):
            with self.subTest(stamp=stamp):
                result=join([{'job':0,'phase':'start'},
                             {'job':0,'phase':'result','accepted':True,'response_ms':stamp}],
                            [{'time':'1970-01-01 00:00:01','command':command}],'UTC')
                self.assertFalse(result['captured'])
                self.assertEqual(len(result['missing']),1)
        result=join([{'job':0,'phase':'start'},
                     {'job':0,'phase':'result','accepted':True,'response_ms':1000}],
                    [None, {'time':'1970-01-01 00:00:01','command':None}],'UTC')
        self.assertEqual(len(result['missing']),1)

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
    def test_uncertain_or_rejected_send_competes_for_shared_publish(self):
        accepted=[{'job':0,'phase':'start','start_ms':1500},
                  {'job':0,'phase':'result','accepted':True,'response_ms':2020,'end_ms':2100}]
        rows=[{'time':'1970-01-01 00:00:02','command':
               {'control':'send_ir','type':0,'head':'h','key1':'k'}}]
        uncertain={'job':1,'phase':'start','start_ms':2900}
        for tail in ([uncertain], [uncertain, {'job':1,'phase':'result','accepted':False,'end_ms':3100}]):
            with self.subTest(tail=tail):
                result=join(accepted+tail,rows,'UTC')
                self.assertFalse(result['captured'])
                self.assertEqual(len(result['missing']),2)
        # An uncertain later request cannot invalidate a distinct, earlier log second.
        result=join(accepted+[dict(uncertain,start_ms=7900)],rows,'UTC')
        self.assertEqual([item['job'] for item in result['captured']],[0])
        self.assertEqual([item['job'] for item in result['missing']],[1])

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
        data={'remote_index':123,'brands':['LG','Samsung'],'control_style':'buttons',
              'codes':[],'default_state':{},
              'keys':[{'id':key,'command':payload} for key in ('power','mode')]}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'index.json').write_text(json.dumps({'profiles':[{'remote_index':123,'manufacturer':'LG','brands':['LG','Samsung'],'control_style':'buttons'}]}))
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

    def fixture(self):
        scope={'keys_by_remote':{'123':['power_off','M0_T25_S0']},'unique_indexes':1,
               'expected_keys':2,'brands':[{'name':'LG','remote_indexes':[123]}]}
        command={'control':'send_ir','type':0,'head':'h','key1':'k','key2':'second-frame'}
        state={'power':True,'mode':'cool','target_temperature':25,'fan':'auto'}
        data={'remote_index':123,'brands':['LG'],'control_style':'state',
              'default_state':{k:v for k,v in state.items() if k!='power'},
              'codes':[{'state':{'power':False},'command':dict(command)},
                       {'state':state,'command':dict(command)}],
              'keys':[{'id':key,'command':dict(command)} for key in scope['keys_by_remote']['123']]}
        metadata={'remote_index':123,'manufacturer':'LG','brands':['LG'],'control_style':'state'}
        return scope,data,metadata

    def verify_fixture(self, scope, data, metadata, legacy=None):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            profiles=[metadata]
            if legacy is not None:
                profiles.append({'remote_index':104800501,'manufacturer':'Carrier'})
                (root/'104800501.json.gz').write_bytes(gzip.compress(json.dumps(legacy).encode()))
            (root/'index.json').write_text(json.dumps({'profiles':profiles}))
            (root/'123.json.gz').write_bytes(gzip.compress(json.dumps(data).encode()))
            return verify(root,scope,require_existing=legacy is not None)

    def test_runtime_state_tables_and_defaults_must_be_usable(self):
        mutations=[
            lambda d:d.update(codes=[]),
            lambda d:d.update(default_state={}),
            lambda d:d['default_state'].update(target_temperature=26),
            lambda d:d['codes'].append(d['codes'][1]),
            lambda d:d['codes'][1]['state'].update(power=1),
            lambda d:d['codes'][1]['state'].update(target_temperature=float('nan')),
            lambda d:d['codes'][1]['command'].update(key1='different-frame'),
            lambda d:d['codes'][1]['command'].update(key2='different-second-frame'),
            lambda d:d['keys'][0]['command'].update(head=123),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                scope,data,metadata=self.fixture()
                mutate(data)
                with self.assertRaises(ValueError):
                    self.verify_fixture(scope,data,metadata)
        scope,data,metadata=self.fixture()
        self.assertEqual(self.verify_fixture(scope,data,metadata),{'remote_indexes':1,'keys':2})

    def test_catalog_style_and_button_state_must_agree(self):
        scope,data,metadata=self.fixture()
        metadata['control_style']='buttons'
        with self.assertRaisesRegex(ValueError,'control style'):
            self.verify_fixture(scope,data,metadata)
        data['control_style']='buttons'
        with self.assertRaisesRegex(ValueError,'absolute state'):
            self.verify_fixture(scope,data,metadata)

    def test_swapped_power_payloads_are_not_accepted_as_original_state_codes(self):
        scope,data,metadata=self.fixture()
        data['keys'][0]['command']['key1']='off-frame'
        data['keys'][1]['command']['key1']='on-frame'
        data['codes'][0]['command']=dict(data['keys'][0]['command'])
        data['codes'][1]['command']=dict(data['keys'][1]['command'])
        self.assertEqual(self.verify_fixture(scope,data,metadata),{'remote_indexes':1,'keys':2})
        data['codes'][0]['command'],data['codes'][1]['command']=data['codes'][1]['command'],data['codes'][0]['command']
        with self.assertRaisesRegex(ValueError,'state mapping'):
            self.verify_fixture(scope,data,metadata)

    def test_preserved_carrier_is_validated_too(self):
        scope,data,metadata=self.fixture()
        legacy=dict(data,remote_index=104800501)
        legacy.pop('control_style')
        self.assertEqual(self.verify_fixture(scope,data,metadata,legacy),{'remote_indexes':1,'keys':2})
        legacy['codes']=[]
        with self.assertRaisesRegex(ValueError,'104800501'):
            self.verify_fixture(scope,data,metadata,legacy)

    def test_invalid_index_and_compressed_files_fail_cleanly(self):
        scope,_,_=self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for value in [None,[],{'profiles':None},{'profiles':[None]},
                          {'profiles':[{'remote_index':True}]}]:
                (root/'index.json').write_text(json.dumps(value))
                with self.subTest(index=value), self.assertRaisesRegex(ValueError,'catalog index'):
                    verify(root,scope)
            (root/'index.json').write_text(json.dumps({'profiles':[{'remote_index':123}]}))
            damaged=gzip.compress(b'{}')[:10]+b'\xff'*10
            for raw in [b'not gzip',damaged,gzip.compress(b'null'),gzip.compress(b'{')]:
                (root/'123.json.gz').write_bytes(raw)
                with self.subTest(raw=raw), self.assertRaises(ValueError):
                    verify(root,scope)

if __name__ == '__main__':
    unittest.main()
