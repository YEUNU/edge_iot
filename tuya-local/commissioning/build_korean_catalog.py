#!/usr/bin/env python3
"""Build only completely captured Tuya remotes; keep incomplete ones out of UI."""
import argparse
import gzip
import json
import re
from pathlib import Path
from export_korean_brands import plan

MODES = {0: 'cool', 1: 'heat', 2: 'auto', 3: 'fanOnly', 4: 'dry'}
FANS = {0: 'auto', 1: 'low', 2: 'medium', 3: 'high'}
LABELS = {'power': '전원 전환', 'power_on': '전원 켜기', 'power_off': '전원 끄기',
          'mode': '모드 변경', 'temperature_up': '온도 올림', 'temperature_down': '온도 내림',
          'wind_speed': '풍량 변경', 'sleep': '취침', 'timing': '예약',
          'ud_wind_mode': '상하 바람', 'lr_wind_mode': '좌우 바람',
          'ud_wind_mode_swing': '상하 회전', 'ud_wind_mode_fix': '바람 고정',
          'wind direction': '바람 방향', 'anion_ac': '음이온', 'fan_speed1': '약풍',
          'fan_speed2': '중풍', 'fan_speed3': '강풍', 'auto wind': '자동 바람',
          'auto speed': '자동 풍량', 'fan': '송풍', 'automatic': '자동 운전',
          'cooling': '냉방', 'dehumidify': '제습', 'supper_power': '강력 운전',
          'energy save': '절전', 'm-wind': '중풍', 'cancel': '예약 취소',
          'fan_speed': '풍량 변경', 'h-wind': '강풍', 'l-wind': '약풍',
          'swing': '바람 회전', 'auto': '자동 운전', 'heating': '난방',
          'aux_heat': '보조 난방', 'air purifying': '공기 정화',
          'lr_wind_mode_swing': '좌우 회전', 'digital stream': '디지털 기류',
          'aid heat': '보조 난방', 'super cooling': '강력 냉방'}


def key_label(key, fallback=None):
    match = re.fullmatch(r'M([0-4])(?:_T(\d+))?(?:_S([0-3]))?', key)
    if match:
        mode, temp, fan = match.groups()
        parts = [{'0':'냉방','1':'난방','2':'자동','3':'송풍','4':'제습'}[mode]]
        if temp is not None: parts.append(temp+'°C')
        if fan is not None: parts.append({'0':'자동 풍량','1':'약풍','2':'중풍','3':'강풍'}[fan])
        return ' · '.join(parts)
    return LABELS.get(key, fallback or key)


def profile(index, records):
    states = {}
    keys = []
    conflicting = False
    for row in records:
        key = row['key']
        keys.append({'id': key, 'name': key_label(key, row.get('key_name', key)),
                     'command': row['command']})
        match = re.fullmatch(r'M([0-4])(?:_T(\d+))?(?:_S([0-3]))?', key)
        keys[-1]['state_control'] = match is not None
        state = None
        if key == 'power_off':
            state = {'power': False}
        elif match:
            mode, temp, fan = match.groups()
            state = {'power': True, 'mode': MODES[int(mode)],
                     'target_temperature': int(temp or 25), 'fan': FANS[int(fan or 0)]}
        if state is not None:
            identity = json.dumps(state, sort_keys=True)
            if identity in states and states[identity]['command'] != row['command']:
                conflicting = True
            states[identity] = {'state': state, 'command': row['command']}
    entries = list(states.values())
    on = [e['state'] for e in entries if e['state']['power']]
    absolute = bool(on) and any(not e['state']['power'] for e in entries) and not conflicting
    default = min(on, key=lambda s: (s['mode'] != 'cool', s['fan'] != 'auto',
                                    abs(s['target_temperature']-25))) if absolute else {}
    brands = records[0]['brands']
    return {'remote_index': index, 'manufacturer': brands[0], 'brands': brands,
            'name': '/'.join(brands) + ' · Tuya ' + str(index), 'models': ['Tuya ' + str(index)],
            'control_style': 'state' if absolute else 'buttons',
            'default_state': {k: v for k, v in default.items() if k != 'power'},
            'codes': entries if absolute else [], 'keys': keys,
            'verification': 'Exact Tuya Publish payloads; appliance compatibility requires user test'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Staging directory, not the installed runtime catalog')
    args = parser.parse_args()
    _, jobs = plan(args.data/'hub-ac-inventory')
    captured = json.loads((args.data/'korean-captured.json').read_text())['captured']
    by_job = {r['job']: r for r in captured}
    expected = {}
    for number, job in enumerate(jobs):
        expected.setdefault(job['remote_index'], []).append((number, job))
    args.output.mkdir(parents=True, exist_ok=True)
    profiles, pending = [], []
    for index, group in expected.items():
        if not all(number in by_job for number, _ in group):
            pending.append(index)
            continue
        records = []
        for number, job in group:
            row = by_job[number]
            if any(row.get(k) != job[k] for k in ('remote_index', 'brands', 'key', 'key_id')):
                raise ValueError('Journal plan mismatch')
            records.append(row)
        converted = profile(index, records)
        (args.output/(str(index)+'.json.gz')).write_bytes(gzip.compress(
            json.dumps(converted, ensure_ascii=False, separators=(',', ':')).encode(), mtime=0))
        profiles.append({k:v for k,v in converted.items() if k not in ('codes', 'keys', 'default_state')})
    result = {'profiles': profiles, 'pending': pending, 'complete': not pending,
              'source': {'kind': 'Tuya user-authorized Publish log export', 'category_id': 5}}
    (args.output/'index.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print('Complete remotes:',len(profiles),'Pending:',len(pending))


if __name__ == '__main__':
    main()
