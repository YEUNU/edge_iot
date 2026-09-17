import copy
import importlib.util
import json
from pathlib import Path
import sys
import threading
import tempfile
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer

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
    def test_off_has_no_stale_temperature(self):
        self.c.command({'power':True})
        self.assertEqual(self.c.command({'power':False})['state'],{'power':False})
        self.assertTrue(self.c.command({'power':True})['state']['power'])

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


class CatalogTests(unittest.TestCase):
    def test_literal_encoder_preserves_leader_and_long_gap(self):
        import base64
        from import_catalog import convert_command, pulses
        from tinytuya.Contrib import IRRemoteControlDevice as IR
        raw=bytes([0,1,40,140,22,53,22,17,22,53,22,17,22,0,13,5])
        packet=base64.b64encode(bytes([0x26,0])+len(raw).to_bytes(2,'little')+raw).decode()
        original=pulses(packet,'Broadlink');encoded=convert_command(packet,'Broadlink')
        decoded=IR.head_key_to_pulses(encoded['head'],encoded['key1'][1:])
        self.assertEqual(len(original),len(decoded))
        for a,b in zip(original,decoded):self.assertLessEqual(abs(a-b),max(35,a*.12))
        self.assertGreater(decoded[0],8000);self.assertGreater(decoded[-1],100000)
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
