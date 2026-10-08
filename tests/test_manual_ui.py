"""Check the user-visible operating constraints independently of the Lua setters."""
import json
import copy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NS = 'earthpanel38939.'


def load(name):
    return json.loads((ROOT / 'smartthings' / name).read_text())


def configured_rows(presentation, config, capability):
    """Resolve the detail rows exposed by a device's JSON patches."""
    result = []
    for entry in config['detailView']:
        if entry['capability'] != capability:
            continue
        rows = copy.deepcopy(presentation['detailView'])
        for patch in entry.get('patch', []):
            path = patch['path'].strip('/').split('/')
            target = rows
            for part in path[:-1]:
                target = target[int(part)] if isinstance(target, list) else target[part]
            key = int(path[-1]) if isinstance(target, list) else path[-1]
            if patch['op'] == 'remove':
                del target[key]
            elif patch['op'] == 'replace':
                target[key] = copy.deepcopy(patch['value'])
            else:
                raise AssertionError('Unexpected presentation operation: ' + patch['op'])
        result.extend(rows)
    return result


class ManualUiTest(unittest.TestCase):
    def test_daily_tuya_controls_expose_connection_and_storage_feedback(self):
        root = ROOT / 'tuya-local'
        link = json.loads((root / 'capabilities/acLocalLink-presentation.json').read_text())
        configs = [root / 'device-configs/tuya-local-ac.json']
        configs.extend(sorted((root / 'device-configs').glob('tuya-local-acTemp*.json')))
        self.assertEqual(len(configs), 10)
        for path in configs:
            with self.subTest(profile=path.stem):
                config = json.loads(path.read_text())
                rows = configured_rows(link, config, NS + 'acLocalLink')
                status = [row for row in rows if row.get('state', {}).get('label') == '{{status.value}}']
                self.assertEqual(len(status), 1, 'Failures and unknown power must remain visible')
                self.assertEqual(status[0]['displayType'], 'state')
                commands = [row.get('pushButton', {}).get('command') for row in rows]
                self.assertIn('configure', commands)
                self.assertIn('showKeys', commands)
                self.assertNotIn('enroll', commands, 'Connection credentials must stay outside everyday controls')
                self.assertEqual(config['detailView'][-1]['capability'], NS + 'acLocalLink')

    def test_all_tuya_temperature_ranges_have_korean_titles(self):
        root = ROOT / 'tuya-local'
        definitions = [path for path in (root / 'capabilities').glob('acTemp*.json')
                       if not path.stem.endswith('-presentation')]
        self.assertEqual(len(definitions), 9)
        for path in definitions:
            with self.subTest(capability=path.stem):
                translation = json.loads((root / 'translations' / (path.stem + '.ko.json')).read_text())
                self.assertEqual(translation['tag'], 'ko')
                self.assertEqual(translation['label'], '설정 온도')

    def test_drying_has_read_only_target_and_manual_modes_have_slider(self):
        for name in ('xiaomi-derh-13l', 'xiaomi-derh-13l-advanced'):
            config = load('device-configs/' + name + '.json')
            rows = [r for r in config['detailView'] if r['capability'] == NS + 'targetHumidity']
            self.assertEqual(len(rows), 1)
            adjustable = rows[0]
            self.assertEqual(adjustable['visibleCondition']['operator'], 'EQUALS')
            self.assertEqual(adjustable['visibleCondition']['value'], 'adjustable.value')
            self.assertEqual(adjustable['visibleCondition']['operand'], 'yes')
            self.assertIn({'op': 'replace', 'path': '/0/slider/range', 'value': [40, 70]}, adjustable['patch'])

    def test_timer_limits_in_detail_and_routines(self):
        for model, maximum in [('fan-za5', 480), ('derh-13l', 720)]:
            for suffix in ('', '-advanced'):
                c = load('device-configs/xiaomi-' + model + suffix + '.json')
                for group in [c['detailView'], c['automation']['conditions'], c['automation']['actions']]:
                    row = next(r for r in group if r['capability'] == NS + ('powerOffTimer' if model == 'fan-za5' else 'dehumidifierTimer'))
                    self.assertIn({'op': 'replace', 'path': '/0/slider/range', 'value': [0, maximum]}, row['patch'])

    def test_purifier_zero_and_standby_filter_reset(self):
        c = load('capabilities/favoriteLevel-presentation.json')
        self.assertEqual(c['detailView'][0]['slider']['range'], [0, 14])
        c = load('device-configs/xiaomi-airp-cpa4-advanced.json')
        row = next(r for r in c['detailView'] if r['capability'] == NS + 'filterMaintenance')
        self.assertEqual(row['visibleCondition']['operand'], 'off')

    def test_drying_state_has_values_and_correct_units(self):
        d = load('capabilities/dryRemainingMinutes-presentation.json')
        self.assertIn('remainingMinutes.value', d['detailView'][0]['state']['label'])
        d = load('capabilities/dryRemainingMinutes.json')
        self.assertEqual(d['attributes']['remainingMinutes']['schema']['properties']['value']['maximum'], 40)
        profile = (ROOT / 'xiaomi-miio/profiles/xiaomi-derh-13l-advanced.yml').read_text()
        for cap in ['dryAfterOff', 'dryRemainingMinutes', 'isWarmingUp', 'dehumidifierTimer']:
            self.assertIn(NS + cap, profile)


if __name__ == '__main__':
    unittest.main()
