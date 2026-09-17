"""Cloud-free Tuya IR air conditioner controller with an explicit codebook.

IR is one-way: state always means last transmitted command, never measured AC state.
"""
import ipaddress
import json
import math
import threading
import gzip
import os
import tempfile
from pathlib import Path


class DeviceError(Exception):
    pass


def validate(config):
    ipaddress.IPv4Address(config['ip'])
    if not isinstance(config['device_id'], str) or not config['device_id']:
        raise ValueError('physical IR hub device_id is required')
    if not isinstance(config['local_key'], str) or len(config['local_key'].encode()) != 16:
        raise ValueError('local_key must contain exactly 16 bytes')
    if config['version'] not in (3.3, 3.4, 3.5):
        raise ValueError('unsupported IR protocol version')
    token = config['api_token']
    if not isinstance(token, str) or len(token) < 32 or not token.isascii() or not token.isalnum():
        raise ValueError('api_token requires at least 32 ASCII letters/digits')
    if config.get('control_type') not in (1, 2):
        raise ValueError('control_type must be 1 (201/202) or 2 (1-13)')
    if type(config.get('remote_index')) is not int or config['remote_index'] < 1:
        raise ValueError('remote_index must identify the installed Tuya code set')
    entries = config['codes']
    button_only = config.get('control_style') == 'buttons'
    if not isinstance(entries, list) or (not entries and not button_only):
        raise ValueError('mapped IR codes required')
    seen = set()
    for entry in entries:
        state = entry['state']
        key = state_key(state)
        if key in seen:
            raise ValueError('duplicate IR state')
        seen.add(key)
        command = entry['command']
        if not isinstance(command, dict) or command.get('control') != 'send_ir' or command.get('type') != 0:
            raise ValueError('only explicit send_ir commands are allowed')
        if not isinstance(command.get('head'), str) or not isinstance(command.get('key1'), str):
            raise ValueError('IR command requires head/key1')
        if len(json.dumps(command)) > 3072 or not command['key1']:
            raise ValueError('invalid IR code size')
    if 'off' not in seen and not button_only:
        raise ValueError('explicit power-off code required (toggle codes unsupported)')
    raw_keys = config.get('keys', [])
    if not isinstance(raw_keys, list) or (button_only and not raw_keys):
        raise ValueError('button remote requires explicit key codes')
    identifiers = set()
    for key in raw_keys:
        identifier = key.get('id')
        command = key.get('command', {})
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            raise ValueError('invalid or duplicate remote key')
        identifiers.add(identifier)
        if (command.get('control') != 'send_ir' or command.get('type') != 0
                or not isinstance(command.get('head'), str) or not command['head']
                or not isinstance(command.get('key1'), str) or not command['key1']
                or len(json.dumps(command)) > 3072):
            raise ValueError('invalid remote key payload')
    return config


def state_key(state):
    if not isinstance(state, dict) or type(state.get('power')) is not bool:
        raise ValueError('state requires Boolean power')
    if not state['power']:
        if set(state) != {'power'}:
            raise ValueError('off state must contain only power')
        return 'off'
    if set(state) != {'power', 'mode', 'fan', 'target_temperature'}:
        raise ValueError('on state requires mode, fan and target_temperature')
    if state['mode'] not in ('cool', 'heat', 'auto', 'dry', 'fanOnly') or (not isinstance(state['fan'], str) or not state['fan'] or len(state['fan']) > 32):
        raise ValueError('unsupported mode or fan')
    temp = state['target_temperature']
    if type(temp) not in (int,float) or not math.isfinite(temp) or not -20 <= temp <= 60:
        raise ValueError('temperature must be finite Celsius within the codebook range')
    return '%s/%s/%g' % (state['mode'], state['fan'], temp)


class Controller:
    def __init__(self, config, factory=None):
        config = dict(config)
        catalog_dir = Path(config.get('catalog_dir', Path(__file__).parent / 'catalog'))
        if not config.get('codes') and config.get('control_style') != 'buttons':
            default = catalog_dir / (str(config['remote_index'])+'.json.gz')
            profile = json.loads(gzip.decompress(default.read_bytes()))
            config.update(profile)
        self.config = validate(config)
        self.profiles = {str(config['remote_index']): config}
        for index, profile in config.get('profiles', {}).items():
            merged = dict(config, **profile)
            merged['remote_index'] = int(index)
            self.profiles[str(index)] = validate(merged)
        self.catalog = {}
        catalog_dir = Path(config.get('catalog_dir', Path(__file__).parent / 'catalog'))
        if (catalog_dir / 'index.json').exists():
            for item in json.loads((catalog_dir / 'index.json').read_text())['profiles']:
                self.catalog[str(item['remote_index'])] = dict(item, path=catalog_dir / (str(item['remote_index'])+'.json.gz'))
        self.saved_settings = {}
        if config.get('settings_path'):
            try:
                saved=json.loads(Path(config['settings_path']).read_text())
                if isinstance(saved,dict):self.saved_settings=saved
            except (OSError,ValueError):pass
        self.profile_id = str(config['remote_index'])
        self.codes = {state_key(e['state']): e for e in config['codes']}
        self.lock = threading.Lock()
        # After restart we cannot know whether another remote changed the appliance.
        self.state = {}
        self.settings = dict(config.get('default_state', {}))
        self._restore_settings()
        if self.settings:
            if state_key(dict(self.settings, power=True)) not in self.codes:
                raise ValueError('default_state must have a mapped code')
        if factory is None:
            import tinytuya
            factory = tinytuya.Device
        self.device = factory(config['device_id'], config['ip'], config['local_key'],
                              version=config['version'], connection_timeout=2,
                              connection_retry_limit=1, connection_retry_delay=0.1)
        self.device.set_socketPersistent(True)
        self.device.set_socketRetryLimit(1)

    def _restore_settings(self):
        saved=self.saved_settings.get(self.profile_id)
        if saved:
            try:
                if state_key(dict(saved,power=True)) in self.codes:self.settings=dict(saved)
            except (ValueError,TypeError):pass

    def _remember_settings(self):
        self.saved_settings[self.profile_id]=dict(self.settings)
        if self.config.get('settings_path'):
            path=Path(self.config['settings_path']);path.parent.mkdir(parents=True,exist_ok=True)
            fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.settings-')
            try:
                with os.fdopen(fd,'w') as f:json.dump(self.saved_settings,f)
                os.replace(tmp,path)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)

    def _send(self, payload):
        response = self.device.set_multiple_values(payload, nowait=True)
        if isinstance(response, dict) and 'Err' in response:
            raise DeviceError('IR hub LAN send failed')
        response = self.device.status()
        if not isinstance(response, dict) or 'Err' in response or 'dps' not in response:
            raise DeviceError('IR hub unreachable after send; command delivery uncertain')
        return response

    def _select(self, profile_id):
        profile_id = str(profile_id or self.config['remote_index'])
        if profile_id not in self.profiles and profile_id in self.catalog:
            profile = json.loads(gzip.decompress(self.catalog[profile_id]['path'].read_bytes()))
            self.profiles[profile_id] = validate(dict(self.config, **profile))
        if profile_id not in self.profiles:
            raise ValueError('code set is not installed on this bridge')
        if profile_id != self.profile_id:
            profile = self.profiles[profile_id]
            self.codes = {state_key(e['state']): e for e in profile['codes']}
            self.settings = dict(profile.get('default_state', {}))
            self.state = {}
            self.profile_id = profile_id
            self._restore_settings()

    def _snapshot(self):
        on = [e['state'] for e in self.codes.values() if e['state']['power']]
        mode = self.settings.get('mode')
        mode_states = [s for s in on if s['mode']==mode] or on
        fan_states = [s for s in mode_states if s['fan']==self.settings.get('fan')] or mode_states
        temps = sorted({s['target_temperature'] for s in fan_states})
        return {'state': dict(self.state), 'confirmed': False, 'state_source': 'last_ir_command',
                'reachable': True, 'profile_id': self.profile_id,
                'profile_name': self.profiles[self.profile_id].get('name',self.profile_id),
                'default_state': self.profiles[self.profile_id].get('default_state',{}),
                'settings': dict(self.settings),
                'control_style': self.profiles[self.profile_id].get('control_style', 'state'),
                'supported_keys': [{'id': k['id'], 'name': k.get('name', k['id'])}
                                   for k in self.profiles[self.profile_id].get('keys', [])
                                   if not k.get('state_control') or self.profiles[self.profile_id].get('control_style') == 'buttons'],
                'supported_modes': sorted({s['mode'] for s in on}),
                'supported_fans': sorted({s['fan'] for s in mode_states}),

                'temperature': {'min': min(temps), 'max': max(temps), 'step': min((b-a for a,b in zip(temps,temps[1:])),default=1)} if temps else None}

    def status(self, profile_id=None):
        with self.lock:
            self._select(profile_id)
            # IR hubs can ignore DP_QUERY after reboot. A harmless study_exit wakes
            # the local channel and elicits a DP response without emitting IR.
            payload = {'201': json.dumps({'control': 'study_exit'})} if self.config['control_type'] == 1 else {'1': 'study_exit'}
            try:
                self._send(payload)
            except DeviceError:
                # Reopen an idle Tuya socket only for the non-IR health query.
                # Never retry a control frame: a lost ACK may still mean delivery.
                self.device.close()
                self._send(payload)
            return self._snapshot()

    def _transmit_ir(self, command):
        if self.config['control_type'] == 1:
            payload = {'201': json.dumps(command)}
        elif command['key1'].startswith('1'):
            payload = {'1': 'study_key', '13': 0, '7': command['key1'][1:]}
        else:
            payload = {'1': 'send_ir', '13': 0, '3': command['head'], '4': command['key1'][1:]}
        self._send(payload)

    def command(self, changes, profile_id=None):
        if isinstance(changes, dict) and set(changes) == {'key'}:
            with self.lock:
                self._select(profile_id)
                key = next((k for k in self.profiles[self.profile_id].get('keys', [])
                            if k['id'] == changes['key']), None)
                if key is None:
                    raise ValueError('remote key is not available for this code set')
                self._transmit_ir(key['command'])
                # Toggle/relative buttons cannot establish absolute AC state.
                self.state = {}
                return self._snapshot()
        if not isinstance(changes, dict) or not changes or not set(changes) <= {'power', 'mode', 'fan', 'target_temperature'}:
            raise ValueError('invalid AC command')
        if 'power' in changes and type(changes['power']) is not bool:
            raise ValueError('power must be Boolean')
        if changes.get('power') is False and len(changes) != 1:
            raise ValueError('power off cannot be combined with settings')
        with self.lock:
            self._select(profile_id)
            if changes.get('power') is False:
                target = {'power': False}
            else:
                # Changing temperature/mode/fan sends a complete power-on frame.
                target = dict(self.settings, **changes)
                target['power'] = True
            key = state_key(target)
            if key not in self.codes and set(changes) == {'mode'}:
                candidates = [e['state'] for e in self.codes.values() if e['state'].get('mode') == changes['mode']]
                if candidates:
                    target = dict(min(candidates, key=lambda s: (s['fan']!=target.get('fan'),abs(s['target_temperature']-target.get('target_temperature',25)))))
                    key = state_key(target)
            if key not in self.codes:
                raise ValueError('no mapped IR code for requested mode/fan/temperature')
            command = self.codes[key]['command']
            self._transmit_ir(command)
            self.state = target
            if target['power']:
                self.settings = {k: v for k, v in target.items() if k != 'power'}
                self._remember_settings()
            return self._snapshot()
