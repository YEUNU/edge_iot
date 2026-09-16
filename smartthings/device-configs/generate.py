"""Generate per-profile UI configuration without changing capability contracts."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NS = 'earthpanel38939.'

def entry(cap):
    return {'component': 'main', 'capability': cap, 'version': 1, 'values': [], 'patch': []}

def patch_row(item, row):
    item['patch'] = [{'op': 'replace', 'path': '/0', 'value': row}]

for profile in sorted((ROOT / 'xiaomi-miio/profiles').glob('*.yml')):
    if profile.stem == 'xiaomi-setup':
        link = entry(NS + 'xiaomiLocalLink')
        link['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '샤오미 기기 연결'}]
        config = {'type': 'profile', 'dashboard': {'states': [entry(NS + 'xiaomiLocalLink')],
                  'actions': []}, 'detailView': [link],
                  'automation': {'conditions': [], 'actions': []}}
        (Path(__file__).parent / (profile.stem + '.json')).write_text(
            json.dumps(config, ensure_ascii=False, indent=2) + '\n')
        continue
    text = profile.read_text()
    caps = re.findall(r'^      - id: (.+)$', text, re.M)
    advanced = 'advanced' in profile.stem
    is_fan = 'fan-za5' in profile.stem
    is_airp = 'airp-cpa4' in profile.stem
    is_derh = 'derh-13l' in profile.stem
    is_alert = profile.stem == 'xiaomi-alerts'
    rows = []
    for cap in caps:
        # Keep API/automation attributes, but avoid redundant filter/legacy-button cards.
        if cap in (NS + 'filterAlert', 'button', 'fanOscillationMode'):
            continue
        # Android renders the standard sensor as a large history chart even
        # when patched to state. Keep its history/dashboard/automation contract,
        # but use a compact read-only mirror in the everyday dehumidifier view.
        if is_derh and cap == ('relativeHumidityMeasurement' if not advanced else NS + 'currentHumidity'):
            continue
        item = entry(cap)
        if cap == NS + 'airPurifierFavoriteLevel':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '{{i18n.label}}'}]
        if cap == NS + 'latestAlert':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '최근 메시지'},
                             {'op': 'replace', 'path': '/1/state/label', 'value': '테스트 보내기'}]
        labels = {NS + 'alarmBuzzer': '조작음', NS + 'indicatorLightMode': '표시등',
                  NS + 'childLock': '버튼 잠금', NS + 'fanOscillationDegrees': '회전 각도 (°)'}
        if cap in labels:
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': labels[cap]}]
        # Binary settings should be one-tap toggles, not two-option dialogs.
        if cap in (NS + 'alarmBuzzer', NS + 'childLock'):
            buzzer = cap == NS + 'alarmBuzzer'
            attr, on, off = ('buzzer', 'on', 'off') if buzzer else ('lock', 'locked', 'unlocked')
            patch_row(item, {'label': labels[cap], 'displayType': 'toggleSwitch',
                            'toggleSwitch': {
                                'command': {'on': 'buzzerOn' if buzzer else 'lock',
                                            'off': 'buzzerOff' if buzzer else 'unlock'},
                                'state': {'value': attr + '.value', 'on': on, 'off': off,
                                          'valueType': 'string', 'label': '{{' + attr + '.value}}',
                                          'alternatives': [
                                              {'key': on, 'value': '켜짐' if buzzer else '잠김', 'type': 'active'},
                                              {'key': off, 'value': '꺼짐' if buzzer else '잠금 해제', 'type': 'inactive'}]}}})
        if cap == 'relativeHumidityMeasurement':
            patch_row(item, {'label': '현재 습도', 'displayType': 'state',
                             'state': {'label': '{{humidity.value}}%'}})
        if cap == 'mode':
            item['patch'] = [{'op': 'replace', 'path': '/0/label',
                              'value': '바람 모드' if is_fan else '운전 모드'}]
        if cap == 'fanSpeedPercent':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '바람 세기'}]
        if cap == 'filterState':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '필터 잔량'}]
            item['patch'].append({'op': 'remove', 'path': '/1'})
        if cap == NS + 'filterMaintenance':
            item['patch'] = [{'op': 'replace', 'path': '/0/label',
                              'value': '필터 교체 후 초기화' if is_airp else '필터 청소 후 초기화'},
                             {'op': 'replace', 'path': '/0/state/label',
                              'value': '교체 후 실행' if is_airp else '청소 후 실행'}]
        if cap == NS + 'currentHumidity':
            item['patch'] = [{'op': 'replace', 'path': '/0/state/label', 'value': '{{humidity.value}} %'}]
        rows.append(item)
    # Main controls retain the same relative order in basic and advanced views.
    priority = ['switch', 'fanSpeedPercent', NS + 'targetHumidity', 'mode', NS + 'airPurifierFavoriteLevel',
                NS + 'fanOscillationControl', NS + 'powerOffTimer', NS + 'fanOscillationDegrees', NS + 'currentHumidity',
                'fineDustSensor', 'relativeHumidityMeasurement',
                'temperatureMeasurement', 'filterState', NS + 'deviceFault',
                NS + 'indicatorLightMode', NS + 'alarmBuzzer', NS + 'childLock',
                NS + 'filterMaintenance', NS + 'latestAlert']
    rows.sort(key=lambda x: priority.index(x['capability']))
    state_cap = (NS + 'latestAlert' if is_alert else 'fanSpeedPercent' if is_fan else
                 'fineDustSensor' if is_airp else 'relativeHumidityMeasurement')
    config = {'type': 'profile', 'dashboard': {'states': [entry(state_cap)],
              'actions': [] if is_alert else [entry('switch')]}, 'detailView': rows,
              'automation': {'conditions': [entry(c) for c in caps if c not in (NS + 'latestAlert', NS + 'filterMaintenance', NS + 'currentHumidity', NS + 'fanOscillationControl')],
                             'actions': [entry(c) for c in caps if c in ('switch', 'mode', 'fanSpeedPercent', 'fanOscillationMode', 'filterState', NS + 'targetHumidity', NS + 'fanOscillationDegrees', NS + 'indicatorLightMode', NS + 'alarmBuzzer', NS + 'childLock', NS + 'powerOffTimer', NS + 'airPurifierFavoriteLevel')]}}
    # Restrict standard enums to what the actual model can do in every view.
    groups = [config['dashboard']['states'], config['dashboard']['actions'], rows,
              config['automation']['conditions'], config['automation']['actions']]
    for group in groups:
        for item in group:
            cap = item['capability']
            if cap == 'fanOscillationMode':
                item['values'] = [{'key': 'fanOscillationMode.value', 'enabledValues': ['fixed', 'horizontal']},
                                  {'key': 'setFanOscillationMode', 'enabledValues': ['fixed', 'horizontal']}]
            if cap == NS + 'deviceFault':
                values = ['noFault', 'motorStuck', 'sensorLost'] if is_airp else [
                    'noFault', 'waterFull', 'sensorFault1', 'sensorFault2', 'commFault1',
                    'filterClean', 'defrost', 'fanMotor', 'overload', 'lackOfRefrigerant']
                item['values'] = [{'key': 'fault.value', 'enabledValues': values}]
    (Path(__file__).parent / (profile.stem + '.json')).write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + '\n')
