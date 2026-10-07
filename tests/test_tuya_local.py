import copy
import json
from email.message import Message
import errno
import io
from pathlib import Path
import sys
import socket
import threading
import tempfile
import unittest
from http.client import HTTPConnection, HTTPResponse
from http.server import HTTPServer
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tuya-local' / 'bridge'))
from controller import Controller, DeviceError
from service import Handler

OFF = {'control':'send_ir', 'type':0, 'head':'test', 'key1':'0off'}
ON = dict(OFF, key1='0on')

def config():
    return {'ip':'192.0.2.19', 'device_id':'test-id', 'local_key':'0'*16,
            'version':3.3, 'api_token':'a'*64, 'remote_index':123, 'control_type':1,
            'default_state':{'mode':'cool','fan':'auto','target_temperature':18},
            'codes':[{'state':{'power':False},'command':OFF},
                     {'state':{'power':True,'mode':'cool','fan':'auto','target_temperature':18},'command':ON}]}

class FakeDevice:
    def __init__(self, *a, **k): self.sent=[]; self.error=False
    def set_socketPersistent(self, *a): pass
    def set_socketRetryLimit(self, *a): pass
    def set_multiple_values(self, values, nowait=False):
        self.sent.append(values)
        return {'Err':'901'} if self.error else None
    def status(self): return {'dps':{'201':'{"control":"study_exit"}'}}

class ControllerTests(unittest.TestCase):
    def setUp(self): self.c = Controller(config(), factory=FakeDevice)
    def test_replays_original_cloud_payload_without_reencoding(self):
        result=self.c.command({'power':True})
        self.assertEqual(json.loads(self.c.device.sent[-1]['201']),ON)
        self.assertFalse(result['confirmed'])
        self.assertEqual(result['state_source'],'last_ir_command')
        self.assertTrue(result['state']['power'])
    def test_status_never_invents_appliance_state(self):
        self.assertEqual(self.c.status()['state'],{})
        self.assertEqual(json.loads(self.c.device.sent[-1]['201']),{'control':'study_exit'})
    def test_rejects_unmapped_temperature_without_sending(self):
        for value in (19,18.5,True,float('nan'),None,'18'):
            with self.assertRaises(ValueError): self.c.command({'target_temperature':value})
        self.assertEqual(self.c.device.sent,[])
    def test_nearby_unmapped_temperatures_never_round_into_an_installed_code(self):
        self.c.command({'power': True})
        before = copy.deepcopy((self.c.state, self.c.settings, self.c.saved_settings))
        sent = len(self.c.device.sent)
        for value in (18.0000001, 17.9999999, 18.0000499):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.c.command({'target_temperature': value})
        self.assertEqual(len(self.c.device.sent), sent)
        self.assertEqual((self.c.state, self.c.settings, self.c.saved_settings), before)

    def test_exact_fractional_codes_are_distinct_and_integer_float_values_match(self):
        cfg = config()
        values = (18.0000001, 18.0000002, 18.5)
        for i, value in enumerate(values):
            cfg['codes'].append({'state': {'power': True, 'mode': 'cool', 'fan': 'auto',
                                           'target_temperature': value},
                                 'command': dict(ON, key1='0fraction' + str(i))})
        c = Controller(cfg, factory=FakeDevice)
        result = c.command({'target_temperature': 18.0})
        self.assertEqual(result['state'], cfg['codes'][1]['state'])
        self.assertEqual(json.loads(c.device.sent[-1]['201']), ON)
        for i, value in enumerate(values):
            result = c.command({'target_temperature': value})
            self.assertEqual(result['state']['target_temperature'], value)
            self.assertEqual(json.loads(c.device.sent[-1]['201'])['key1'], '0fraction' + str(i))
        duplicate = copy.deepcopy(cfg['codes'][1])
        duplicate['state']['target_temperature'] = 18.0
        cfg['codes'].append(duplicate)
        with self.assertRaisesRegex(ValueError, 'duplicate IR state'):
            Controller(cfg, factory=FakeDevice)

    def test_saved_and_default_temperatures_require_an_exact_mapped_code(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg = config()
            cfg['settings_path'] = str(Path(directory) / 'settings.json')
            saved = dict(cfg['default_state'], target_temperature=18.0000001)
            Path(cfg['settings_path']).write_text(json.dumps({'123': saved}))
            c = Controller(cfg, factory=FakeDevice)
            self.assertEqual(c.settings, cfg['default_state'])
            self.assertEqual(c.state, {})
            cfg['default_state'] = saved
            with self.assertRaisesRegex(ValueError, 'default_state must have a mapped code'):
                Controller(cfg, factory=FakeDevice)

    def test_ir_payload_type_must_be_explicit_integer_zero_before_device_creation(self):
        from unittest.mock import Mock
        for value in (False, True, 0.0, '0', None):
            for style in ('state', 'buttons'):
                with self.subTest(value=value, style=style):
                    cfg = copy.deepcopy(config())
                    if style == 'state':
                        cfg['codes'][0]['command']['type'] = value
                    else:
                        cfg.update(codes=[], default_state={}, control_style='buttons',
                                   keys=[{'id':'power', 'command':dict(OFF, type=value)}])
                    factory = Mock()
                    with self.assertRaises(ValueError):
                        Controller(cfg, factory=factory)
                    factory.assert_not_called()
        for command in (None, [], 'send_ir'):
            with self.subTest(command=command):
                cfg = config()
                cfg.update(codes=[], default_state={}, control_style='buttons',
                           keys=[{'id':'power', 'command':command}])
                with self.assertRaises(ValueError):
                    Controller(cfg, factory=FakeDevice)
    def test_failed_send_does_not_publish_new_state(self):
        self.c.command({'power':True}); self.c.device.error=True
        with self.assertRaises(DeviceError): self.c.command({'power':False})
        self.assertTrue(self.c.state['power'])
    def test_type_two_converts_cloud_head_key_prefix(self):
        c=config();c['control_type']=2;c=Controller(c,factory=FakeDevice)
        c.command({'power':False})
        self.assertEqual(c.device.sent[-1],{'1':'send_ir','13':0,'3':'test','4':'off'})
    def test_profile_switch_clears_assumed_state(self):
        c=config();c['profiles']={'456':{'name':'Replacement','codes':copy.deepcopy(c['codes'])}}
        c=Controller(c,factory=FakeDevice);c.command({'power':True})
        self.assertEqual(c.status('456')['state'],{})
        with self.assertRaises(ValueError): c.command({'power':False},'789')
    def test_restart_restores_settings_without_inventing_power(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg=config();cfg['settings_path']=str(Path(directory)/'settings.json')
            cfg['codes'].append({'state':{'power':True,'mode':'cool','fan':'auto','target_temperature':26},'command':ON})
            original=Controller(cfg,factory=FakeDevice)
            original.command({'target_temperature':26})
            restarted=Controller(cfg,factory=FakeDevice)
            result=restarted.status()
            self.assertEqual(result['settings']['target_temperature'],26)
            self.assertEqual(result['state'],{})
            self.assertFalse(result['confirmed'])
            Path(cfg['settings_path']).write_text('[]')
            self.assertEqual(Controller(cfg,factory=FakeDevice).settings['target_temperature'],18)
    def test_deeply_nested_corrupt_settings_fall_back_without_blocking_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg = config()
            cfg['settings_path'] = str(Path(directory) / 'settings.json')
            Path(cfg['settings_path']).write_text('[' * 1200 + '0' + ']' * 1200)
            c = Controller(cfg, factory=FakeDevice)
            self.assertEqual(c.settings, cfg['default_state'])
            self.assertEqual(c.saved_settings, {})
            self.assertEqual(c.state, {})
            self.assertEqual(c.device.sent, [])

    def test_off_has_no_stale_temperature(self):
        self.c.command({'power':True})
        self.assertEqual(self.c.command({'power':False})['state'],{'power':False})
        self.assertTrue(self.c.command({'power':True})['state']['power'])

    def test_storage_errors_retry_only_settings_and_preserve_successful_ir(self):
        failures = [('controller.Path.mkdir', PermissionError('denied')),
                    ('controller.tempfile.mkstemp', OSError(errno.ENOSPC, 'full')),
                    ('controller.json.dump', OSError(errno.ENOSPC, 'full')),
                    ('controller.os.replace', PermissionError('denied'))]
        for target, error in failures:
            with self.subTest(stage=target), tempfile.TemporaryDirectory() as directory:
                cfg = config()
                cfg['settings_path'] = str(Path(directory) / 'settings.json')
                c = Controller(cfg, factory=FakeDevice)
                with patch(target, side_effect=error):
                    result = c.command({'power': True})
                self.assertTrue(result['state']['power'])
                self.assertTrue(result['settings_save_pending'])
                self.assertEqual(len(c.device.sent), 1)
                recovered = c.status()
                self.assertFalse(recovered['settings_save_pending'])
                self.assertEqual(len(c.device.sent), 2)
                self.assertEqual(json.loads(c.device.sent[-1]['201']), {'control': 'study_exit'})
                self.assertEqual(json.loads(Path(cfg['settings_path']).read_text())['123'], c.settings)
                self.assertEqual(Controller(cfg, factory=FakeDevice).settings, c.settings)
                self.assertEqual(Controller(cfg, factory=FakeDevice).state, {})

    def test_missing_storage_path_and_cleanup_failure_do_not_fail_commands(self):
        with patch('controller.tempfile.mkstemp', side_effect=AssertionError('unexpected save')):
            result = self.c.command({'power': True})
            self.assertFalse(result['settings_save_pending'])
        with tempfile.TemporaryDirectory() as directory:
            cfg = config()
            cfg['settings_path'] = str(Path(directory) / 'settings.json')
            c = Controller(cfg, factory=FakeDevice)
            with patch('controller.os.unlink', side_effect=PermissionError('cleanup failed')):
                result = c.command({'power': True})
            self.assertFalse(result['settings_save_pending'])
            self.assertTrue(Path(cfg['settings_path']).is_file())
            self.assertEqual(len(c.device.sent), 1)

    def test_failed_ir_does_not_save_new_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            self.c.config['settings_path'] = str(Path(directory) / 'settings.json')
            self.c.device.error = True
            with patch('controller.os.replace') as save:
                with self.assertRaises(DeviceError): self.c.command({'power': True})
            save.assert_not_called()
            self.assertFalse(self.c.settings_save_pending)
            self.assertEqual(self.c.saved_settings, {})
            self.assertEqual(len(self.c.device.sent), 1)

    def test_invalid_field_types_never_transmit_ir(self):
        cases = {'power': [None, 0, 1, 'true', [], {}],
                 'mode': [None, True, 1, [], {}, 'invalid'],
                 'fan': [None, True, 1, [], {}, '', 'x' * 33],
                 'target_temperature': [None, True, '18', [], {}, float('nan'), float('inf'), -float('inf'), 10 ** 400, -10 ** 400]}
        for field, values in cases.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.c.command({field: value})
        self.assertEqual(self.c.device.sent, [])

class HttpTests(unittest.TestCase):
    def setUp(self):
        self.server=HTTPServer(('127.0.0.1',0),Handler)
        self.server.controller=Controller(config(),factory=FakeDevice)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def tearDown(self): self.server.shutdown();self.server.server_close();self.thread.join()
    def request(self, path, payload=None, token=True, profile='123'):
        c=HTTPConnection(*self.server.server_address,timeout=2)
        headers={'X-IR-Profile':profile}
        if token:headers['Authorization']='Bearer '+'a'*64
        c.request('POST' if payload is not None else 'GET',path,body=payload,headers=headers)
        r=c.getresponse();status=r.status;body=json.loads(r.read());c.close();return status,body
    def test_auth_required_and_secret_not_returned(self):
        self.assertEqual(self.request('/v1/state',token=False)[0],401)
        code,body=self.request('/v1/state');self.assertEqual(code,200)
        self.assertNotIn('local_key',json.dumps(body))
    def test_invalid_and_unsupported_requests(self):
        self.assertEqual(self.request('/v1/command','[]')[0],400)
        self.assertEqual(self.request('/v1/command','{"target_temperature":19}')[0],400)
        self.assertEqual(self.request('/v1/state',profile='unknown')[0],400)
        self.assertEqual(self.request('/missing')[0],404)
        self.assertEqual(self.request('/v1/command',json.dumps({'target_temperature':10 ** 400}))[0],400)
    def test_unmapped_nearby_temperature_is_rejected_over_http_without_ir_or_settings_change(self):
        c = self.server.controller
        before = copy.deepcopy((c.state, c.settings, c.saved_settings))
        for value in (18.0000001, 17.9999999, 18.0000499):
            with self.subTest(value=value):
                self.assertEqual(self.request('/v1/command', json.dumps({'target_temperature': value}))[0], 400)
        self.assertEqual(c.device.sent, [])
        self.assertEqual((c.state, c.settings, c.saved_settings), before)
    def test_malformed_json_and_wrong_token_do_not_send_ir(self):
        for body in ('{', 'null', 'true', '[]', '{}', '{"power":1}', 'x'*2049):
            self.assertEqual(self.request('/v1/command',body)[0],400)
        c=HTTPConnection(*self.server.server_address,timeout=2)
        c.request('POST','/v1/command','{"power":true}',{'Authorization':'Bearer '+'b'*64})
        r=c.getresponse();self.assertEqual(r.status,401);r.read();c.close()
        self.assertEqual(self.server.controller.device.sent,[])
    def test_bridge_reports_failure_then_recovers_without_false_state(self):
        self.server.controller.device.error=True
        code,body=self.request('/v1/command','{"power":true}')
        self.assertEqual(code,502)
        self.assertEqual(self.server.controller.state,{})
        self.server.controller.device.error=False
        code,body=self.request('/v1/command','{"power":true}')
        self.assertEqual(code,200);self.assertTrue(body['state']['power'])
    def test_state_after_command(self):
        code,body=self.request('/v1/command','{"power":true}')
        self.assertEqual(code,200);self.assertTrue(body['state']['power']);self.assertFalse(body['confirmed'])

    def test_storage_failure_returns_success_then_poll_recovers_without_ir_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'settings.json'
            path.mkdir()
            self.server.controller.config['settings_path'] = str(path)
            code, body = self.request('/v1/command', '{"power":true}')
            self.assertEqual(code, 200)
            self.assertTrue(body['state']['power'])
            self.assertTrue(body['settings_save_pending'])
            self.assertEqual(len(self.server.controller.device.sent), 1)
            path.rmdir()
            code, body = self.request('/v1/state')
            self.assertEqual(code, 200)
            self.assertFalse(body['settings_save_pending'])
            self.assertTrue(body['state']['power'])
            self.assertEqual(len(self.server.controller.device.sent), 2)
            self.assertEqual(json.loads(self.server.controller.device.sent[-1]['201']), {'control': 'study_exit'})

    def raw_request(self, path, body, headers, half_close=True):
        with socket.create_connection(self.server.server_address, timeout=2) as connection:
            wire = 'POST ' + path + ' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
            wire += 'Authorization: Bearer ' + 'a' * 64 + '\r\n'
            pairs = headers.items() if isinstance(headers, dict) else headers
            wire += ''.join(name + ': ' + value + '\r\n' for name, value in pairs)
            connection.sendall(wire.encode() + b'\r\n' + body)
            if half_close: connection.shutdown(socket.SHUT_WR)
            response = HTTPResponse(connection)
            response.begin()
            return response.status, json.loads(response.read())

    def test_truncated_or_slow_body_never_transmits_ir_or_redeems_ticket(self):
        class FastHandler(Handler):
            request_timeout = 0.05
        self.server.RequestHandlerClass = FastHandler
        class Tickets:
            calls = 0
            def redeem(self, *_):
                self.calls += 1
                return True
        self.server.pairing = Tickets()
        for half_close in (True, False):
            for path, body in [('/v1/command', b'{"power":true}'),
                               ('/v1/pair', b'{"ticket":"test","device_id":"owned"}')]:
                with self.subTest(path=path, half_close=half_close):
                    code, _ = self.raw_request(path, body, {'Content-Length': str(len(body) + 1)}, half_close)
                    self.assertEqual(code, 400)
        self.assertEqual(self.server.controller.device.sent, [])
        self.assertEqual(self.server.pairing.calls, 0)

    def test_bad_lengths_and_transfer_encoding_do_not_transmit_ir(self):
        for length in ('-1', '0', '2049', '1.5', 'NaN', 'true'):
            with self.subTest(length=length):
                self.assertEqual(self.raw_request('/v1/command', b'{}', {'Content-Length': length})[0], 400)
        self.assertEqual(self.raw_request('/v1/command', b'{}', {'Content-Length': '2', 'Transfer-Encoding': 'chunked'})[0], 400)
        self.assertEqual(self.server.controller.device.sent, [])

    def test_ambiguous_http_framing_never_sends_ir_or_consumes_ticket(self):
        class Tickets:
            calls = 0
            def redeem(self, *_):
                self.calls += 1
                return True
        self.server.pairing = Tickets()
        for path, body in [('/v1/command', b'{"power":true}'),
                           ('/v1/pair', b'{"ticket":"test","device_id":"owned"}')]:
            length = str(len(body))
            cases = [
                [('Content-Length', length), ('Content-Length', length)],
                [('Content-Length', length), ('Content-Length', str(len(body)+1))],
                [('Content-Length', length), ('Transfer-Encoding', '')],
                [('Content-Length', '+'+length)],
                [('Content-Length', '1_3')],
                [],
            ]
            for headers in cases:
                with self.subTest(path=path, headers=headers):
                    self.assertEqual(self.raw_request(path, body, headers)[0], 400)
        self.assertEqual(self.server.controller.device.sent, [])
        self.assertEqual(self.server.pairing.calls, 0)

    def test_response_write_failure_does_not_reclassify_or_repeat_device_delivery(self):
        class Disconnected:
            statuses = []
            def reply(self, status, data):
                self.statuses.append(status)
                raise BrokenPipeError('client disconnected')
        handler = Disconnected()
        with self.assertRaises(BrokenPipeError):
            Handler.run_device(handler, lambda: self.server.controller.command({'power': True}))
        self.assertEqual(handler.statuses, [200])
        self.assertEqual(len(self.server.controller.device.sent), 1)
        self.assertTrue(self.server.controller.state['power'])

    def test_response_write_failure_does_not_redeem_ticket_again_or_reply_twice(self):
        body = b'{"ticket":"test","device_id":"owned"}'
        class Tickets:
            calls = 0
            def redeem(self, *_):
                self.calls += 1
                return True
        class Disconnected:
            headers = Message()
            headers['Content-Length'] = str(len(body))
            read_json_body = Handler.read_json_body
            rfile = io.BytesIO(body)
            statuses = []
            server = SimpleNamespace(pairing=Tickets(), controller=self.server.controller)
            def reply(self, status, data):
                self.statuses.append(status)
                raise BrokenPipeError('client disconnected')
        handler = Disconnected()
        with self.assertRaises(BrokenPipeError): Handler.pair(handler)
        self.assertEqual(handler.statuses, [200])
        self.assertEqual(handler.server.pairing.calls, 1)


class CatalogTests(unittest.TestCase):
    def test_catalog_loads_without_cloud_and_selects_lazily(self):
        import gzip
        from controller import validate
        folder=ROOT/'tuya-local/bridge/catalog'
        index=json.loads((folder/'index.json').read_text())
        c=Controller(config(),factory=FakeDevice)
        for p in index['profiles']:
            data=json.loads(gzip.decompress((folder/(str(p['remote_index'])+'.json.gz')).read_bytes()))
            validate(dict(config(),**data))
            result=c.status(str(p['remote_index']))
            self.assertLess(len(json.dumps(result)),16384)
            self.assertEqual(result['state'],{})
            if data.get('control_style') == 'buttons':
                self.assertTrue(result['supported_keys'])
                with self.assertRaises(ValueError):
                    c.command({'power':True},str(p['remote_index']))
                continue
            self.assertTrue(c.command({'power':True},str(p['remote_index']))['state']['power'])
            self.assertEqual(c.command({'power':False},str(p['remote_index']))['state'],{'power':False})


class ButtonRemoteTests(unittest.TestCase):
    def test_button_only_remote_never_invents_absolute_state(self):
        cfg = config()
        cfg.update(codes=[], default_state={}, control_style='buttons',
                   keys=[{'id':'power', 'name':'전원 전환', 'command': ON}])
        c = Controller(cfg, factory=FakeDevice)
        result = c.command({'key':'power'})
        self.assertEqual(json.loads(c.device.sent[-1]['201']), ON)
        self.assertEqual(result['state'], {})
        self.assertEqual(result['settings'], {})
        self.assertEqual(result['control_style'], 'buttons')
        self.assertEqual(result['supported_keys'][0]['id'], 'power')
        with self.assertRaises(ValueError): c.command({'power':False})
        with self.assertRaises(ValueError): c.command({'key':'missing'})
        self.assertEqual(len(c.device.sent), 1)

    def test_extra_button_invalidates_last_absolute_state(self):
        cfg = config()
        cfg['keys'] = [{'id':'temperature_up', 'command':ON}]
        c = Controller(cfg, factory=FakeDevice)
        c.command({'power':True})
        self.assertEqual(c.command({'key':'temperature_up'})['state'], {})

if __name__ == '__main__':
    unittest.main()
