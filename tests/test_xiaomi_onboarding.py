import io
import json
from pathlib import Path
from email.message import Message
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'xiaomi-miio/onboarding'))
from transfer import Transfer, encode, decode
from onboard import cloud_devices, normalize


class OnboardingTests(unittest.TestCase):
    def test_codec_and_tampering(self):
        key = b'A'*16
        raw = encode(key, {'devices':[{'token':'not a household secret'}]})
        self.assertEqual(decode(key,raw)['devices'][0]['token'],'not a household secret')
        with self.assertRaises(ValueError): decode(key,raw[:-1]+bytes([raw[-1]^1]))
        with self.assertRaises(ValueError): decode(b'B'*16,raw)

    def test_normalize_deduplicate_filter(self):
        record={'did':'123','localip':'192.168.1.2','token':'ab'*16,'model':'zhimi.fan.za5'}
        self.assertEqual(len(normalize([record,record])),1)
        for change in [{'token':'0'*32},{'localip':'127.0.0.1'},{'model':'unsupported'},{'did':'no'}]:
            self.assertEqual(normalize([{**record,**change}]),[])

    def test_transfer_expiry_and_single_use(self):
        t=Transfer('127.0.0.1','127.0.0.1','setup',[{'did':123}])
        port=t.start()
        def post(path,key=None):
            data=encode(key or t.key,{'device_id':'setup'})
            return urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=data),timeout=3)
        try:
            with self.assertRaises(urllib.error.HTTPError): post('/bundle',b'B'*16)
            response=decode(t.key,post('/bundle').read())
            self.assertEqual(response['devices'],[{'did':123}])
            with self.assertRaises(urllib.error.HTTPError): post('/bundle')
            t.deadline=time.monotonic()-1
            with self.assertRaises(urllib.error.HTTPError): post('/ack')
        finally: t.close()

    def test_actual_lua_transport_and_import(self):
        t=Transfer('127.0.0.1','127.0.0.1','setup',[{'did':123,'ip':'192.168.1.2','token':'ab'*16,'model':'zhimi.fan.za5'}])
        port=t.start()
        # Transport uses loopback only in the fixture; production rejects it.
        script=r'''
package.path = "xiaomi-miio/src/?.lua;" .. package.path
package.preload["cosock.socket"] = function() return require "socket" end
package.preload["st.json"] = function() return require "dkjson" end
package.preload.log = function() return {info=function()end,warn=function()end,error=function()end} end
local json = require "dkjson"
local args=json.decode(io.read("*a"))
local connection=require "connection"
local valid=connection.valid_ip
connection.valid_ip=function(ip) return ip=="127.0.0.1" or valid(ip) end
local Client=require "miio.client"
Client.new=function() return {begin_session=function()return {dev_id=123}end,miio_info=function(_,session)assert(session.dev_id==123);return {model="zhimi.fan.za5"} end} end
local driver={datastore={},get_devices=function()return {} end}
local created=0
function driver:try_create_device(metadata) assert(metadata.model=="zhimi.fan.za5");created=created+1;return true end
local status
require("enrollment").handle(driver,{id="setup",model="xiaomi.setup"},args,function(s)status=s end)
assert(created==1, status)
assert(driver.datastore["discovered:xiaomi-miio-123"].token==string.rep("ab",16))
assert(driver.xiaomi_enrolling==false)
print("LUA_IMPORT_OK")
'''
        try:
            proc=subprocess.run(['lua','-e',script],input=json.dumps({'address':'127.0.0.1','port':port,'ticket':t.key.hex()}),capture_output=True,text=True,cwd=ROOT,timeout=10)
            self.assertEqual(proc.returncode,0,proc.stderr)
            self.assertEqual(t.result,{'updated':0,'requested':1,'failed':0})
            self.assertTrue(t.done.wait(1))
        finally:t.close()

    def test_lua_enrollment_edge_cases(self):
        proc = subprocess.run(['lua', 'tests/test_xiaomi_enrollment.lua', '.'], capture_output=True,
                              text=True, cwd=ROOT, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('24 enrollment edge-case tests passed', proc.stdout)

    def make_transfer(self, *, started=True, **kwargs):
        transfer = Transfer('127.0.0.1', '127.0.0.1', 'setup', [{'did': 123}], **kwargs)
        self.addCleanup(transfer.close)
        if started:
            transfer.start()
        return transfer

    @staticmethod
    def post(transfer, path, value):
        data = encode(transfer.key, value)
        request = urllib.request.Request(f'http://127.0.0.1:{transfer.server.server_port}{path}', data=data)
        with urllib.request.urlopen(request, timeout=3) as response:
            return decode(transfer.key, response.read())

    def handler(self, transfer, path, value, *, content_length=None, write_error=False, headers=None):
        raw = encode(transfer.key, value)
        response = Mock()
        if write_error:
            response.write.side_effect = BrokenPipeError()
        fake = SimpleNamespace(
            connection=Mock(), client_address=('127.0.0.1', 1000), path=path,
            headers=headers if headers is not None else {'Content-Length': str(len(raw)) if content_length is None else content_length},
            rfile=io.BytesIO(raw), wfile=response, send_response=Mock(), send_header=Mock(),
            end_headers=Mock(), send_error=Mock(),
        )
        transfer.server.RequestHandlerClass.do_POST(fake)
        return fake

    def test_bundle_exposes_only_remaining_lifetime(self):
        transfer = self.make_transfer()
        bundle = self.post(transfer, '/bundle', {'device_id': 'setup'})
        self.assertGreater(bundle['expires_in'], 0)
        self.assertLessEqual(bundle['expires_in'], 120)
        self.assertEqual(bundle['device_id'], 'setup')

    def test_authenticated_scalar_or_wrong_device_requests_are_rejected(self):
        transfer = self.make_transfer(started=False)
        for value in [None, False, 42, 'request', [], {'device_id': 'another'}]:
            with self.subTest(value=value):
                handler = self.handler(transfer, '/bundle', value)
                handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
                self.assertFalse(transfer.claimed)

    def test_expiry_while_reading_body_does_not_claim_bundle(self):
        transfer = self.make_transfer(started=False)
        transfer.deadline = 100
        with patch('transfer.time.monotonic', side_effect=[99, 101]):
            handler = self.handler(transfer, '/bundle', {'device_id': 'setup'})
        handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
        self.assertFalse(transfer.claimed)

    def test_expired_or_wrong_hub_requests_cannot_claim_bundle(self):
        transfer = self.make_transfer(started=False)
        transfer.deadline = time.monotonic() - 1
        handler = self.handler(transfer, '/bundle', {'device_id': 'setup'})
        handler.send_error.assert_called_once_with(403)
        self.assertFalse(transfer.claimed)
        transfer.deadline = time.monotonic() + 120
        transfer.hub = '192.168.1.50'
        handler = self.handler(transfer, '/bundle', {'device_id': 'setup'})
        handler.send_error.assert_called_once_with(403)
        self.assertFalse(transfer.claimed)

    def test_invalid_body_lengths_are_rejected(self):
        transfer = self.make_transfer(started=False)
        for length in ['not-a-number', '-1', '32', '16385']:
            with self.subTest(length=length):
                handler = self.handler(transfer, '/bundle', {'device_id': 'setup'}, content_length=length)
                handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
                self.assertFalse(transfer.claimed)

    def test_ack_validates_counters_and_preserves_partial_failure(self):
        transfer = self.make_transfer(started=False)
        transfer.claimed = True
        invalid = [None, [], {}, {'updated': 0, 'requested': 1},
                   {'updated': False, 'requested': 1, 'failed': 0},
                   {'updated': 0.0, 'requested': 1, 'failed': 0},
                   {'updated': -1, 'requested': 2, 'failed': 0},
                   {'updated': 0, 'requested': 0, 'failed': 0},
                   {'updated': 0, 'requested': 1, 'failed': 0, 'extra': 0}]
        for result in invalid:
            with self.subTest(result=result):
                handler = self.handler(transfer, '/ack', {'device_id': 'setup', 'result': result})
                handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
                self.assertIsNone(transfer.result)
                self.assertFalse(transfer.done.is_set())
        result = {'updated': 0, 'requested': 0, 'failed': 1}
        handler = self.handler(transfer, '/ack', {'device_id': 'setup', 'result': result})
        handler.send_response.assert_called_once_with(200)
        self.assertEqual(transfer.result, result)
        self.assertTrue(transfer.done.is_set())
        reused = self.handler(transfer, '/ack', {'device_id': 'setup', 'result': result})
        reused.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')

    def test_ack_response_loss_still_confirms_received_result(self):
        transfer = self.make_transfer(started=False)
        transfer.claimed = True
        result = {'updated': 1, 'requested': 0, 'failed': 0}
        handler = self.handler(transfer, '/ack', {'device_id': 'setup', 'result': result}, write_error=True)
        self.assertEqual(transfer.result, result)
        self.assertTrue(transfer.done.is_set())
        handler.send_error.assert_not_called()

    def test_ack_before_bundle_is_rejected(self):
        transfer = self.make_transfer(started=False)
        handler = self.handler(transfer, '/ack', {'device_id': 'setup', 'result': {'updated': 0, 'requested': 1, 'failed': 0}})
        handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
        self.assertIsNone(transfer.result)

    def test_transfer_lifecycle_and_nonfinite_ttl(self):
        for ttl in [0, -1, float('nan'), float('inf'), 121, True, '120', 10**400, -(10**400)]:
            with self.subTest(ttl=ttl):
                with self.assertRaises(ValueError):
                    Transfer('127.0.0.1', '127.0.0.1', 'setup', [], ttl=ttl)
        transfer = self.make_transfer(started=False)
        transfer.close()
        transfer.close()
        with self.assertRaises(RuntimeError):
            transfer.start()
        started = self.make_transfer()
        self.assertEqual(started.start(), started.server.server_port)
        started.close()
        self.assertEqual(started.key, b'')
        self.assertEqual(started.devices, [])

    def test_truncated_http_body_cannot_claim_or_ack(self):
        transfer = self.make_transfer(started=False)
        request = {'device_id': 'setup'}
        length = len(encode(transfer.key, request))
        handler = self.handler(transfer, '/bundle', request, content_length=str(length + 1))
        handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
        self.assertFalse(transfer.claimed)
        transfer.claimed = True
        request['result'] = {'updated': 0, 'requested': 1, 'failed': 0}
        length = len(encode(transfer.key, request))
        handler = self.handler(transfer, '/ack', request, content_length=str(length + 1))
        handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
        self.assertIsNone(transfer.result)
        self.assertFalse(transfer.done.is_set())

    def test_ambiguous_http_framing_is_rejected(self):
        transfer = self.make_transfer(started=False)
        request = {'device_id': 'setup'}
        length = str(len(encode(transfer.key, request)))
        for lengths, encoding in [([length, length], None), ([length, str(int(length) + 1)], None),
                                  ([length], 'chunked'), ([length], ''), ([], None)]:
            with self.subTest(lengths=lengths, encoding=encoding):
                headers = Message()
                for value in lengths:
                    headers['Content-Length'] = value
                if encoding is not None:
                    headers['Transfer-Encoding'] = encoding
                handler = self.handler(transfer, '/bundle', request, headers=headers)
                handler.send_error.assert_called_once_with(400, 'Invalid or expired enrollment request')
                self.assertFalse(transfer.claimed)

    def test_normalize_malformed_rows_do_not_hide_supported_devices(self):
        record = {'did': '123', 'localip': '192.168.1.2', 'token': 'ab'*16, 'model': 'zhimi.fan.za5'}
        for container in [None, False, 42, 'records', {}]:
            with self.subTest(container=container):
                self.assertEqual(normalize(container), [])
        rows = [None, False, 42, 'device', [], {}, {**record, 'did': True},
                {**record, 'did': 123.5}, {**record, 'did': float('nan')},
                {**record, 'did': float('inf')}, {**record, 'token': None}, {**record, 'model': []}, {**record, 'model': {}},
                {**record, 'localip': True}, record]
        self.assertEqual(normalize(rows), [{'did': 123, 'ip': '192.168.1.2', 'token': 'ab'*16, 'model': 'zhimi.fan.za5'}])

    def test_normalize_device_limit_and_boundary_ids(self):
        record = {'did': '123', 'localip': '192.168.1.2', 'token': 'ab'*16, 'model': 'zhimi.fan.za5'}
        self.assertEqual(len(normalize([{**record, 'did': str(i)} for i in range(1, 21)])), 20)
        with self.assertRaisesRegex(RuntimeError, 'More than 20'):
            normalize([{**record, 'did': str(i)} for i in range(1, 22)])
        for did in [0, -1, 0xffffffff, 0x100000000]:
            self.assertEqual(normalize([{**record, 'did': did}]), [])
        self.assertEqual(normalize([{**record, 'did': 0xfffffffe}])[0]['did'], 0xfffffffe)

    @staticmethod
    def cloud_connector(**overrides):
        record = {'did': '123', 'localip': '192.168.1.2', 'token': 'ab'*16, 'model': 'zhimi.fan.za5'}
        methods = {
            'userId': '9',
            'get_homes': Mock(return_value={'code': 0, 'result': {'homelist': [{'id': 1}]}}),
            'get_dev_cnt': Mock(return_value={'code': 0, 'result': {'share': {'share_family': []}}}),
            'get_devices': Mock(return_value={'code': 0, 'result': {'device_info': [record]}}),
        }
        methods.update(overrides)
        return SimpleNamespace(**methods)

    def test_cloud_lookup_deduplicates_homes_and_accepts_empty_optional_lists(self):
        connector = self.cloud_connector(get_dev_cnt=Mock(return_value={
            'code': 0, 'result': {'share': {'share_family': [{'home_id': '1', 'home_owner': 9}]}}}))
        self.assertEqual(len(cloud_devices(connector, ['cn'])), 1)
        connector.get_devices.assert_called_once_with('cn', 1, 9)
        for result in [{'homelist': None}, {'homelist': []}]:
            connector = self.cloud_connector(get_homes=Mock(return_value={'code': 0, 'result': result}),
                                             get_dev_cnt=Mock(return_value={'code': 0, 'result': {'share': None}}))
            self.assertEqual(cloud_devices(connector, ['cn']), [])
            connector.get_devices.assert_not_called()
        connector = self.cloud_connector(get_devices=Mock(return_value={'code': 0, 'result': {'device_info': None}}))
        self.assertEqual(cloud_devices(connector, ['cn']), [])

    def test_cloud_api_errors_are_never_reported_as_no_supported_devices(self):
        for value in [None, False, 42, 'response', [], {}, {'code': 1, 'result': {}},
                      {'code': False, 'result': {}}, {'code': 0, 'result': {}}, {'code': 0, 'result': None}, {'code': 0, 'result': []}]:
            for method in ['get_homes', 'get_dev_cnt', 'get_devices']:
                with self.subTest(method=method, value=value):
                    connector = self.cloud_connector(**{method: Mock(return_value=value)})
                    with self.assertRaisesRegex(RuntimeError, 'cloud device lookup failed'):
                        cloud_devices(connector, ['cn'])

    def test_cloud_malformed_home_or_list_does_not_suppress_independent_lookup(self):
        for malformed in [None, False, 42, 'home', [], {}, {'id': []}, {'id': True}]:
            connector = self.cloud_connector(get_homes=Mock(return_value={
                'code': 0, 'result': {'homelist': [malformed, {'id': 1}]}}))
            with self.subTest(home=malformed), self.assertRaises(RuntimeError):
                cloud_devices(connector, ['cn'])
            connector.get_devices.assert_called_once_with('cn', 1, 9)
        bad_lists = [False, 42, 'list', {}]
        for value in bad_lists:
            for method, result in [('get_homes', {'homelist': value}),
                                   ('get_dev_cnt', {'share': value}),
                                   ('get_dev_cnt', {'share': {'share_family': value}}),
                                   ('get_devices', {'device_info': value})]:
                if method == 'get_dev_cnt' and result == {'share': {}}:
                    continue  # A successful empty share mapping has no shared homes.
                with self.subTest(method=method, value=value):
                    connector = self.cloud_connector(**{method: Mock(return_value={'code': 0, 'result': result})})
                    with self.assertRaises(RuntimeError):
                        cloud_devices(connector, ['cn'])

    def test_cloud_exceptions_are_redacted_and_other_regions_are_checked(self):
        def homes(region):
            if region == 'cn':
                raise RuntimeError('credential-bearing account URL')
            return {'code': 0, 'result': {'homelist': [{'id': 1}]}}
        connector = self.cloud_connector(get_homes=Mock(side_effect=homes))
        with self.assertRaises(RuntimeError) as caught:
            cloud_devices(connector, ['cn', 'de'])
        self.assertNotIn('credential-bearing', str(caught.exception))
        self.assertEqual(connector.get_homes.call_count, 2)
        connector.get_devices.assert_called_once_with('de', 1, 9)

    def test_cloud_device_rows_are_normalized_without_account_requests(self):
        record = {'did': '123', 'localip': '192.168.1.2', 'token': 'ab'*16, 'model': 'zhimi.fan.za5'}
        connector = self.cloud_connector(get_devices=Mock(return_value={
            'code': 0, 'result': {'device_info': [None, 42, 'device', {'model': []}, record]}}))
        self.assertEqual(len(cloud_devices(connector, ['cn'])), 1)

if __name__=='__main__':unittest.main()
