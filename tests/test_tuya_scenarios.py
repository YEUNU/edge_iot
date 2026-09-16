"""Behavioral coverage: full catalog replay, transitions, outages and concurrency.

Uses a simulated Tuya transport; never emits physical IR.
"""
import copy
import gzip
import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from test_tuya_local import config, FakeDevice, ROOT, ON, Controller, DeviceError

class ScenarioTests(unittest.TestCase):
    def rich_config(self):
        cfg=config()
        for mode,fan,temp in [('cool','auto',26),('cool','high',26),('dry','auto',25),('heat','low',30)]:
            cfg['codes'].append({'state':dict(power=True,mode=mode,fan=fan,target_temperature=temp),'command':dict(ON,key1='0'+mode+fan+str(temp))})
        return cfg

    def test_all_74743_catalog_frames_replay_exact_original_payload(self):
        count=0
        for path in sorted((ROOT/'tuya-local/bridge/catalog').glob('*.json.gz')):
            profile=json.loads(gzip.decompress(path.read_bytes()))
            controller=Controller(dict(config(),**profile),factory=FakeDevice)
            for entry in profile['codes']:
                result=controller.command(entry['state'])
                self.assertEqual(json.loads(controller.device.sent[-1]['201']),entry['command'],str(path))
                self.assertEqual(result['state'],entry['state'])
                self.assertFalse(result['confirmed'])
                controller.device.sent.clear();count+=1
        self.assertEqual(count,74743)

    def test_mode_transition_uses_supported_combination_and_rejects_bad_fan(self):
        c=Controller(self.rich_config(),factory=FakeDevice)
        c.command({'target_temperature':26});c.command({'fan':'high'})
        result=c.command({'mode':'dry'})
        self.assertEqual(result['state'],dict(power=True,mode='dry',fan='auto',target_temperature=25))
        self.assertEqual(result['supported_fans'],['auto'])
        self.assertEqual(result['temperature']['min'],25)
        sent=len(c.device.sent)
        for bad in [{'fan':'high'},{'target_temperature':26},{'mode':'cool','fan':'unsupported'}]:
            with self.assertRaises(ValueError):c.command(bad)
        self.assertEqual(len(c.device.sent),sent)

    def test_power_off_preserves_next_power_on_settings(self):
        c=Controller(self.rich_config(),factory=FakeDevice)
        c.command({'mode':'heat'})
        c.command({'power':False})
        self.assertEqual(c.command({'power':True})['state'],dict(power=True,mode='heat',fan='low',target_temperature=30))

    def test_invalid_input_never_sends_ir_or_changes_state(self):
        c=Controller(self.rich_config(),factory=FakeDevice)
        for bad in [None,[],{},'on',{'unknown':1},{'power':1},{'power':False,'mode':'cool'},
                    {'target_temperature':-21},{'target_temperature':61},{'target_temperature':float('inf')},
                    {'mode':'bogus'},{'fan':''}]:
            with self.assertRaises(ValueError):c.command(bad)
        self.assertEqual(c.state,{})
        self.assertEqual(c.device.sent,[])

    def test_idle_socket_health_check_recovers_without_retrying_ir(self):
        class Idle(FakeDevice):
            stale=True
            def status(self):return {'Err':'timeout'} if self.stale else super().status()
            def close(self):self.stale=False
        c=Controller(config(),factory=Idle)
        self.assertTrue(c.status()['reachable'])
        self.assertEqual(len(c.device.sent),2)
        for payload in c.device.sent:self.assertEqual(json.loads(payload['201']),{'control':'study_exit'})
        c.device.stale=True;sent=len(c.device.sent)
        with self.assertRaises(DeviceError):c.command({'power':True})
        self.assertEqual(len(c.device.sent),sent+1,'uncertain IR command must never be retried')

    def test_lost_ack_is_uncertain_and_later_command_recovers(self):
        class Flaky(FakeDevice):
            reachable=True
            def status(self):return super().status() if self.reachable else {'Err':'timeout'}
        c=Controller(self.rich_config(),factory=Flaky)
        c.command({'target_temperature':26});before=copy.deepcopy(c.state)
        c.device.reachable=False
        with self.assertRaises(DeviceError):c.command({'power':False})
        self.assertEqual(c.state,before)
        c.device.reachable=True
        self.assertEqual(c.command({'power':False})['state'],{'power':False})

    def test_profile_settings_stay_separate_and_switching_does_not_emit_ir(self):
        cfg=self.rich_config();cfg['profiles']={'456':{'name':'Other','codes':copy.deepcopy(cfg['codes'])}}
        with tempfile.TemporaryDirectory() as directory:
            cfg['settings_path']=str(Path(directory)/'settings.json')
            c=Controller(cfg,factory=FakeDevice)
            c.command({'target_temperature':26},'123');c.command({'mode':'heat'},'456')
            c.device.sent.clear();a=c.status('123')
            self.assertEqual(a['settings']['target_temperature'],26)
            self.assertEqual(a['state'],{})
            self.assertEqual(json.loads(c.device.sent[-1]['201']),{'control':'study_exit'})
            c=Controller(cfg,factory=FakeDevice)
            self.assertEqual(c.status('456')['settings']['target_temperature'],30)
            self.assertEqual(c.state,{})

    def test_parallel_clients_do_not_mix_profile_commands(self):
        cfg=self.rich_config();cfg['profiles']={'456':{'name':'Other','codes':copy.deepcopy(cfg['codes'])}}
        c=Controller(cfg,factory=FakeDevice)
        cases=[('123',{'mode':'heat'}),('456',{'mode':'dry'})]*20
        with ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda case:c.command(case[1],case[0]),cases))
        for (profile,changes),result in zip(cases,results):
            self.assertEqual(result['profile_id'],profile)
            self.assertEqual(result['state']['mode'],changes['mode'])
        self.assertEqual(len(c.device.sent),len(cases))

if __name__=='__main__':unittest.main()
