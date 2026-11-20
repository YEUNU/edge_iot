"""Generate per-profile UI configuration without changing capability contracts."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = json.loads((ROOT / 'integration.json').read_text())['namespace']
NS = NAMESPACE + '.'

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
        # Keep API/automation attributes, but avoid redundant filter/oscillation cards.
        if cap in (NS + 'filterAlert', 'fanOscillationMode'):
            continue
        # Android renders the standard sensor as a large history chart even
        # when patched to state. Keep its history/dashboard/automation contract,
        # but use a compact read-only mirror in the everyday dehumidifier view.
        if is_derh and cap == ('relativeHumidityMeasurement' if not advanced else NS + 'currentHumidity'):
            continue
        item = entry(cap)
        if cap == NS + 'airPurifierFavoriteLevel':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '수동 풍량'}]
            item['visibleCondition'] = {'capability': 'mode', 'version': 1,
                'component': 'main', 'value': 'mode.value', 'operator': 'EQUALS',
                'operand': '즐겨찾기'}
        if is_derh and cap == NS + 'targetHumidity':
            item['visibleCondition'] = {'capability': NS + 'targetHumidity', 'version': 1,
                'component': 'main', 'value': 'adjustable.value', 'operator': 'EQUALS',
                'operand': 'yes', 'valueType': 'string', 'hideOnUnmatch': False}
        if cap == NS + 'dryAfterOff':
            patch_row(item, {'label': '종료 후 내부 건조', 'displayType': 'toggleSwitch',
                'toggleSwitch': {'command': {'on': 'enable', 'off': 'disable'},
                    'state': {'value': 'dryAfterOff.value', 'on': 'on', 'off': 'off',
                              'valueType': 'string'}}})
        if cap == NS + 'latestAlert':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '최근 메시지'},
                             {'op': 'replace', 'path': '/1/state/label', 'value': '테스트 보내기'}]
        labels = {NS + 'alarmBuzzer': '조작음', NS + 'indicatorLightMode': '표시등',
                  NS + 'childLock': '버튼 잠금', NS + 'fanOscillationDegrees': '회전 각도',
                  NS + 'powerOffTimer': '꺼짐 예약', NS + 'dehumidifierTimer': '꺼짐 예약'}
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
        if cap == 'temperatureMeasurement':
            patch_row(item, {'label': '현재 온도', 'displayType': 'state',
                             'state': {'label': '{{temperature.value}}°C'}})
        if is_fan and cap == NS + 'fanOscillationDegrees':
            item['visibleCondition'] = {'capability': NS + 'fanOscillationControl', 'version': 1,
                'component': 'main', 'value': 'fanOscillationMode.value', 'operator': 'EQUALS',
                'operand': 'horizontal', 'valueType': 'string', 'hideOnUnmatch': False}
        if is_derh and cap == NS + 'dryRemainingMinutes':
            item['visibleCondition'] = {'capability': NS + 'dryRemainingMinutes', 'version': 1,
                'component': 'main', 'value': 'remainingMinutes.value', 'operator': 'GREATER_THAN',
                'operand': '0', 'valueType': 'integer', 'hideOnUnmatch': True}
        if is_derh and cap == NS + 'isWarmingUp':
            item['visibleCondition'] = {'capability': NS + 'isWarmingUp', 'version': 1,
                'component': 'main', 'value': 'warmingUp.value', 'operator': 'EQUALS',
                'operand': 'yes', 'valueType': 'string', 'hideOnUnmatch': True}
        if cap == 'fineDustSensor':
            patch_row(item, {'label': '초미세먼지', 'displayType': 'state',
                             'state': {'label': '{{fineDustLevel.value}} ㎍/㎥'}})
        if cap == 'mode':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '운전 모드'}]
        if cap == 'fanSpeedPercent':
            item['patch'] = [{'op': 'replace', 'path': '/0/label', 'value': '바람 세기'}]
        if cap == 'filterState':
            patch_row(item, {'label': '필터 잔량', 'displayType': 'state',
                             'state': {'label': '{{filterLifeRemaining.value}}%'}})
            item['patch'].append({'op': 'remove', 'path': '/1'})
        if cap == NS + 'filterMaintenance':
            item['patch'] = [{'op': 'replace', 'path': '/0/label',
                              'value': '필터 교체 후 초기화' if is_airp else '필터 청소 후 초기화'},
                             {'op': 'replace', 'path': '/0/state/label',
                              'value': '교체 후 실행' if is_airp else '청소 후 실행'}]
            if is_airp:
                item['visibleCondition'] = {'capability': 'switch', 'version': 1,
                    'component': 'main', 'value': 'switch.value', 'operator': 'EQUALS',
                    'operand': 'off'}
        if cap == NS + 'currentHumidity':
            item['patch'] = [{'op': 'replace', 'path': '/0/state/label', 'value': '{{humidity.value}}%'}]
        rows.append(item)
    # Unified 7-section layout across all appliances:
    # 1. power -> 2. mode -> 3. intensity/target -> 4. auxiliary/timer ->
    # 5. sensors/status -> 6. device settings -> 7. maintenance actions
    priority = ['switch', 'mode',
                'fanSpeedPercent', NS + 'targetHumidity', NS + 'airPurifierFavoriteLevel',
                NS + 'fanOscillationControl', NS + 'fanOscillationDegrees',
                NS + 'powerOffTimer', NS + 'dehumidifierTimer',
                'fineDustSensor', NS + 'currentHumidity', 'relativeHumidityMeasurement',
                'temperatureMeasurement', 'filterState', NS + 'deviceFault',
                NS + 'dryRemainingMinutes', NS + 'isWarmingUp',
                NS + 'indicatorLightMode', NS + 'alarmBuzzer', NS + 'childLock',
                NS + 'dryAfterOff',
                NS + 'filterMaintenance', NS + 'latestAlert']
    rows.sort(key=lambda x: priority.index(x['capability']))
    # Dashboard state drives both the label and active/inactive card styling.
    # Sensor values remain available while off, so they cannot represent power.
    state_cap = NS + 'latestAlert' if is_alert else 'switch'
    config = {'type': 'profile', 'dashboard': {'states': [entry(state_cap)],
              'actions': [] if is_alert else [entry('switch')]}, 'detailView': rows,
              'automation': {'conditions': [entry(c) for c in caps if c not in (NS + 'latestAlert', NS + 'filterMaintenance', NS + 'currentHumidity', NS + 'fanOscillationControl')],
                             'actions': [entry(c) for c in caps if c in ('switch', 'mode', 'fanSpeedPercent', 'fanOscillationMode', 'filterState', NS + 'targetHumidity', NS + 'fanOscillationDegrees', NS + 'indicatorLightMode', NS + 'alarmBuzzer', NS + 'childLock', NS + 'powerOffTimer', NS + 'dehumidifierTimer', NS + 'airPurifierFavoriteLevel', NS + 'dryAfterOff')]}}
    # Restrict standard enums to what the actual model can do in every view.
    groups = [config['dashboard']['states'], config['dashboard']['actions'], rows,
              config['automation']['conditions'], config['automation']['actions']]
    for group in groups:
        for item in group:
            cap = item['capability']
            if cap in (NS + 'targetHumidity', NS + 'powerOffTimer', NS + 'dehumidifierTimer'):
                limits = [40, 70] if cap == NS + 'targetHumidity' else [0, 480 if is_fan else 720]
                if not any(p.get('path') == '/0' for p in item['patch']):
                    item['patch'].append({'op': 'replace', 'path': '/0/slider/range', 'value': limits})
            if cap == 'mode' and (is_airp or is_fan or is_derh):
                mode_pairs = (
                    [('자동', '자동'), ('수면', '수면'), ('즐겨찾기', '수동')] if is_airp else
                    [('자연풍', '자연풍'), ('직선풍', '직선풍')] if is_fan else
                    [('스마트', '스마트'), ('수면', '수면'), ('옷 건조', '옷 건조')]
                )
                alternatives = [{'key': key, 'value': label, 'type': 'active'}
                                for key, label in mode_pairs]
                paths = (['/0/list/command/alternatives', '/0/list/state/alternatives']
                         if group is rows else ['/0/list/alternatives'])
                item['patch'].extend({'op': 'replace', 'path': path, 'value': alternatives}
                                     for path in paths)
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
