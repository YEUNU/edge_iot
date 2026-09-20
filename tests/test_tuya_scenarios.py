"""Behavioral coverage: full catalog replay, transitions, outages and concurrency.

Uses a simulated Tuya transport; never emits physical IR.
"""
import copy
import gzip
import json
import tempfile
import unittest
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from test_tuya_local import config, FakeDevice, ROOT, ON, Controller, DeviceError

sys.path.insert(0,str(ROOT/'tuya-local/commissioning'))

class ScenarioTests(unittest.TestCase):
    def rich_config(self):
        cfg=config()
        for mode,fan,temp in [('cool','auto',26),('cool','high',26),('dry','auto',25),('heat','low',30)]:
            cfg['codes'].append({'state':dict(power=True,mode=mode,fan=fan,target_temperature=temp),'command':dict(ON,key1='0'+mode+fan+str(temp))})
        return cfg

    def test_all_catalog_frames_replay_exact_original_payload(self):
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
        self.assertEqual(count,7635)

    def test_every_requested_tuya_key_replays_complete_payload(self):
        from verify_korean_release import verify
        folder=ROOT/'tuya-local/bridge/catalog'
        scope=json.loads((ROOT/'tuya-local/commissioning/KOREAN_SCOPE.json').read_text())
        self.assertEqual(verify(folder,scope,require_existing=True)['keys'],7723)
        count=0
        for path in folder.glob('*.json.gz'):
            profile=json.loads(gzip.decompress(path.read_bytes()))
            c=Controller(dict(config(),**profile),factory=FakeDevice)
            for key in profile.get('keys',[]):
                result=c.command({'key':key['id']})
                self.assertEqual(json.loads(c.device.sent[-1]['201']),key['command'])
                self.assertEqual(result['state'],{})
                self.assertFalse(result['confirmed'])
                c.device.sent.clear();count+=1
        self.assertEqual(count,7723)

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

    def test_stale_client_recreated_only_for_health_and_preserves_state(self):
        instances=[]
        class Stale(FakeDevice):
            stale=False
            def __init__(self,*a,**k):
                super().__init__(*a,**k);instances.append(self)
            def status(self):return {'Err':'timeout'} if self.stale else super().status()
            def close(self):pass  # Socket close does not clear protocol state.
        c=Controller(config(),factory=Stale)
        c.command({'power':True})
        before=copy.deepcopy((c.state,c.settings,c.profile_id))
        old=c.device;old.stale=True;old.sent.clear()
        with self.assertRaises(DeviceError):c.command({'power':False})
        self.assertEqual(len(instances),1)
        self.assertEqual(len(old.sent),1,'failed IR command must not be replayed')
        old.sent.clear()
        result=c.status()
        self.assertTrue(result['reachable'])
        self.assertEqual(len(instances),2)
        self.assertEqual((c.state,c.settings,c.profile_id),before)
        self.assertEqual([len(d.sent) for d in instances],[2,1])
        for d in instances:
            for payload in d.sent:self.assertEqual(json.loads(payload['201']),{'control':'study_exit'})

    def test_unreachable_health_has_bounded_recovery_and_stays_failed(self):
        instances=[]
        class Unreachable(FakeDevice):
            def __init__(self,*a,**k):
                super().__init__(*a,**k);instances.append(self)
            def status(self):return {'Err':'timeout'}
            def close(self):pass
        c=Controller(config(),factory=Unreachable)
        with self.assertRaises(DeviceError):c.status()
        self.assertEqual(len(instances),2)
        self.assertEqual([len(d.sent) for d in instances],[2,1])
        self.assertEqual(c.state,{})

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
