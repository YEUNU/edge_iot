#!/usr/bin/env python3
"""Build native SmartThings selectors, bounded temperature profiles, and remote-key views from the offline catalogue."""
import gzip
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = json.loads((ROOT.parent / 'integration.json').read_text())['namespace']
NS = NAMESPACE + '.'
CATALOG_DIR = ROOT / 'bridge/catalog'


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def attribute(kind='string'):
    value = {'type': kind}
    if kind == 'array':
        value['items'] = {'type': 'string'}
    return {'schema': {'type': 'object', 'properties': {'value': value},
                       'required': ['value'], 'additionalProperties': False}}


def row(cap, patch=None):
    return {'component': 'main', 'capability': cap, 'version': 1, 'values': [], 'patch': patch or []}


def build_model_library():
    index = json.loads((CATALOG_DIR / 'index.json').read_text())
    allowed_brands = {'Samsung', 'LG', 'Carrier', 'Winia'}
    profiles = sorted(index['profiles'], key=lambda p: (p['manufacturer'], p['remote_index']))
    if any(p['manufacturer'] not in allowed_brands for p in profiles):
        raise ValueError('Only the four requested AC brands may be installed')
    priority = {'Samsung': 0, 'LG': 1, 'Carrier': 2, 'Winia': 3}
    brands = sorted({b for p in profiles for b in p.get('brands', [p['manufacturer']])},
                    key=lambda b: (priority.get(b, 4), b))
    brand_labels = {'Samsung': '삼성', 'LG': 'LG', 'Carrier': '캐리어', 'Winia': '위니아'}

    cap = {'name': 'AC Model Library', 'attributes': {k: attribute() for k in ['brand', 'candidate', 'status']}, 'commands': {}}
    cap['attributes']['supportedCandidates'] = attribute('array')
    cap['attributes']['brand']['setter'] = 'setBrand'
    cap['attributes']['brand']['schema']['properties']['value']['enum'] = brands
    cap['attributes']['candidate']['setter'] = 'setCandidate'
    cap['attributes']['candidate']['schema']['properties']['value']['enum'] = [p['name'] for p in profiles]
    for command, arg in [('setBrand', 'brand'), ('setCandidate', 'candidate'), ('applyCode', None)]:
        cap['commands'][command] = {'name': command, 'arguments': (
            [{'name': arg, 'optional': False, 'schema': {'type': 'string'}}] if arg else [])}
    for attr_name, command in [('brand', 'setBrand'), ('candidate', 'setCandidate')]:
        cap['commands'][command]['arguments'][0]['schema']['enum'] = (
            cap['attributes'][attr_name]['schema']['properties']['value'].pop('enum'))

    presentation = {'dashboard': {'states': [], 'actions': [], 'panelItems': []},
                    'detailView': [], 'automation': {'conditions': [], 'actions': []}}

    def model_kind(p):
        rid = str(p['remote_index'])
        data = json.loads(gzip.decompress((CATALOG_DIR / (rid + '.json.gz')).read_bytes()))
        if data.get('control_style') == 'buttons':
            return '버튼형', '창문/이동식 (버튼형)'
        codes = [e['state'] for e in data.get('codes', []) if e['state'].get('power')]
        temps = sorted({s['target_temperature'] for s in codes})
        modes = {s['mode'] for s in codes}
        lo, hi = min(temps), max(temps)
        temp_text = f'{lo}°C 단일' if lo == hi else f'{lo}~{hi}°C'
        if 'heat' in modes:
            kind = '냉난방' if ('auto' in modes or 'fanOnly' in modes) else '냉방·제습·난방'
        elif len(modes) == 1:
            kind = '냉방단순형'
        else:
            kind = '냉방전용'
        return kind, f'{temp_text} {kind}'

    def model_label(p):
        rid = str(p['remote_index'])
        if p['remote_index'] == 104800501:
            return '기존 캐리어 (18~30°C 냉난방) · 104800501'
        _, summary = model_kind(p)
        return f'{summary} · {rid}'

    for attr_name, label, values, command in [
        ('brand', '제조사', [{'key': b, 'value': brand_labels.get(b, b)} for b in brands], 'setBrand'),
        ('candidate', '기종', [{'key': p['name'], 'value': model_label(p)} for p in profiles], 'setCandidate'),
    ]:
        model = {'command': {'name': command, 'alternatives': values, 'argumentType': 'string'},
                 'state': {'value': attr_name + '.value', 'alternatives': values}}
        if attr_name == 'candidate':
            model['command']['supportedValues'] = 'supportedCandidates.value'
        presentation['detailView'].append({'label': label, 'displayType': 'list', 'list': model})
    presentation['detailView'].append({'label': '반응 확인 · 기종 저장', 'displayType': 'pushButton',
                                       'pushButton': {'command': 'applyCode'}})
    presentation['detailView'].append({'label': '설정 안내', 'displayType': 'state',
                                       'state': {'label': '{{status.value}}'}})
    write(ROOT / 'capabilities/acModelLibrary.json', cap)
    write(ROOT / 'capabilities/acModelLibrary-presentation.json', presentation)

    lines = ['return {']
    for p in profiles:
        aliases = '{' + ','.join(json.dumps(b) for b in p.get('brands', [p['manufacturer']])) + '}'
        kind, _ = model_kind(p)
        lines.append('  [%s]={brand=%s,brands=%s,style=%s,name=%s,label=%s},' % (
            json.dumps(str(p['remote_index'])), json.dumps(p['manufacturer'], ensure_ascii=False),
            aliases, json.dumps(p.get('control_style', 'state')),
            json.dumps(p['name'], ensure_ascii=False), json.dumps(kind, ensure_ascii=False)))
    (ROOT / 'src/catalog.lua').write_text('\n'.join(lines + ['}']) + '\n')
    return index, profiles, brands


def build_temperature_profiles(profiles):
    ranges, by_id = {}, {}
    for p in profiles:
        data = json.loads(gzip.decompress((CATALOG_DIR / (str(p['remote_index']) + '.json.gz')).read_bytes()))
        temps = sorted({e['state']['target_temperature'] for e in data['codes'] if e['state']['power']})
        if not temps:
            if data.get('control_style') == 'buttons':
                continue
            raise ValueError('State profile has no temperatures')
        lo, hi = min(temps), max(temps)
        slug = f'acTemp{lo}To{hi}'
        ranges[slug] = (lo, hi)
        by_id[str(p['remote_index'])] = slug
    base = re.sub(r'\nmetadata:[\s\S]*', '', (ROOT / 'profiles/tuya-local-ac.yml').read_text())
    basecfg = json.loads((ROOT / 'device-configs/tuya-local-ac.json').read_text())
    for slug, (lo, hi) in ranges.items():
        cap = {'name': f'AC Temp {lo} To {hi}', 'attributes': {
            'temperature': {'schema': {'type': 'object', 'properties': {
                'value': {'type': 'number', 'minimum': lo, 'maximum': hi},
                'unit': {'type': 'string', 'enum': ['C'], 'default': 'C'},
            }, 'required': ['value'], 'additionalProperties': False}, 'setter': 'setTemperature'},
            'temperatureRange': {'schema': {'type': 'object', 'properties': {
                'value': {'type': 'object', 'properties': {
                    'minimum': {'type': 'number'}, 'maximum': {'type': 'number'}, 'step': {'type': 'number'},
                }, 'required': ['minimum', 'maximum', 'step'], 'additionalProperties': False},
            }, 'required': ['value'], 'additionalProperties': False}},
        }, 'commands': {'setTemperature': {'name': 'setTemperature', 'arguments': [
            {'name': 'temperature', 'optional': False, 'schema': {'type': 'number', 'minimum': lo, 'maximum': hi}}]}}}
        presentation = {'dashboard': {'states': [], 'actions': []}, 'detailView': [
            {'label': '설정 온도', 'displayType': 'slider', 'slider': {
                'value': 'temperature.value', 'unit': 'temperature.unit', 'command': 'setTemperature',
                'range': [lo, hi], 'step': 1, 'supportedValues': 'temperatureRange.value'}}],
            'automation': {'conditions': [], 'actions': []}}
        write(ROOT / f'capabilities/{slug}.json', cap)
        write(ROOT / f'capabilities/{slug}-presentation.json', presentation)
        write(ROOT / f'translations/{slug}.ko.json', {'tag': 'ko', 'label': '설정 온도', 'attributes': {}, 'commands': {}})
        text = (base.replace('name: tuya-local-ac.v1', f'name: tuya-local-ac.{slug}.v1')
                .replace('      - id: thermostatCoolingSetpoint',
                         f'      - id: {NS}{slug}\n        version: 1\n      - id: thermostatCoolingSetpoint'))
        profile_path = ROOT / f'profiles/tuya-local-{slug}.yml'
        if profile_path.exists() and '\nmetadata:' in profile_path.read_text():
            text += '\nmetadata:' + profile_path.read_text().split('\nmetadata:', 1)[1]
        profile_path.write_text(text)
        cfg = json.loads(json.dumps(basecfg))
        for item in cfg['detailView']:
            if item['capability'] == 'thermostatCoolingSetpoint':
                item['capability'] = NS + slug
                item['patch'] = []
        write(ROOT / f'device-configs/tuya-local-{slug}.json', cfg)
    lines = ['return {', '  by_id={']
    for profile_id, slug in by_id.items():
        lines.append(f'    ["{profile_id}"]="{slug}",')
    lines += ['  },', '  types={']
    for slug in sorted(ranges):
        lines.append(f'    "{slug}",')
    lines += ['  }', '}']
    (ROOT / 'src/temperature_profiles.lua').write_text('\n'.join(lines) + '\n')
    return ranges


def build_remote_keys():
    cap = {'name': 'AC Remote Keys', 'attributes': {'key': attribute('string'), 'supportedKeys': attribute('array')},
           'commands': {'selectKey': {'name': 'selectKey', 'arguments': [
               {'name': 'key', 'optional': False, 'schema': {'type': 'string'}}]},
               'sendKey': {'name': 'sendKey', 'arguments': []}, 'back': {'name': 'back', 'arguments': []}}}
    cap['attributes']['key']['setter'] = 'selectKey'
    keys = json.loads((ROOT / 'commissioning/KOREAN_KEYS.json').read_text())
    alternatives = [{'key': key, 'value': label} for key, label in sorted(keys.items())]
    presentation = {'dashboard': {'states': [], 'actions': []}, 'detailView': [
        {'label': '리모컨 버튼', 'displayType': 'list', 'list': {
            'command': {'name': 'selectKey', 'supportedValues': 'supportedKeys.value',
                        'argumentType': 'string', 'alternatives': alternatives},
            'state': {'value': 'key.value', 'alternatives': alternatives}}},
        {'label': '선택한 버튼 보내기', 'displayType': 'pushButton', 'pushButton': {'command': 'sendKey'}},
        {'label': '돌아가기', 'displayType': 'pushButton', 'pushButton': {'command': 'back'}}],
        'automation': {'conditions': [], 'actions': []}}
    write(ROOT / 'capabilities/acRemoteKeys.json', cap)
    write(ROOT / 'capabilities/acRemoteKeys-presentation.json', presentation)

    for suffix in ('keys', 'buttons', 'setup-buttons'):
        capabilities = [NS + 'acRemoteKeys', NS + 'acLocalLink', 'refresh']
        if suffix == 'setup-buttons':
            capabilities.insert(0, NS + 'acModelLibrary')
        text = f'name: tuya-local-ac.{suffix}.v1\ncomponents:\n  - id: main\n    capabilities:\n'
        for c in capabilities:
            text += f'      - id: {c}\n        version: 1\n'
        text += '    categories:\n      - name: AirConditioner\n'
        profile = ROOT / f'profiles/tuya-local-ac-{suffix}.yml'
        if profile.exists() and '\nmetadata:' in profile.read_text():
            text += '\nmetadata:' + profile.read_text().split('\nmetadata:', 1)[1]
        profile.write_text(text)
        rawpatch = [] if suffix == 'keys' else [{'op': 'remove', 'path': '/2'}]
        detail = [row(NS + 'acRemoteKeys', rawpatch)]
        if suffix == 'setup-buttons':
            detail.insert(0, row(NS + 'acModelLibrary'))
            linkpatch = [{'op': 'remove', 'path': '/2'}, {'op': 'remove', 'path': '/1'},
                         {'op': 'replace', 'path': '/0', 'value': {
                             'label': '변경 취소', 'displayType': 'pushButton', 'pushButton': {'command': 'done'}}}]
        else:
            linkpatch = [{'op': 'remove', 'path': '/2'}]
            if suffix == 'keys':
                linkpatch.append({'op': 'remove', 'path': '/1'})
        detail.append(row(NS + 'acLocalLink', linkpatch))
        write(ROOT / f'device-configs/tuya-local-ac-{suffix}.json', {
            'type': 'profile', 'dashboard': {'states': [row(NS + 'acLocalLink')], 'actions': []},
            'detailView': detail, 'automation': {'conditions': [], 'actions': []}})


def main():
    index, profiles, brands = build_model_library()
    ranges = build_temperature_profiles(index['profiles'])
    build_remote_keys()
    print(f'{len(profiles)} code sets; {len(brands)} brands; {len(ranges)} temperature profiles')


if __name__ == '__main__':
    main()
