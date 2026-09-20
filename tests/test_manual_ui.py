"""Check the user-visible operating constraints independently of the Lua setters."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NS = 'earthpanel38939.'


def load(name):
    return json.loads((ROOT / 'smartthings' / name).read_text())


class ManualUiTest(unittest.TestCase):
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
                    row = next(r for r in group if r['capability'] == NS + 'powerOffTimer')
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
        for cap in ['dryAfterOff', 'dryRemainingMinutes', 'isWarmingUp', 'powerOffTimer']:
            self.assertIn(NS + cap, profile)


if __name__ == '__main__':
    unittest.main()
