#!/usr/bin/env python3
"""One-time, read-only inventory of AC remotes offered to this Tuya hub.

Not imported or included by the runtime image. Resumes successful reads from
private files. Never sends IR, adds a remote, or changes the existing remote.
An index is metadata, not an executable local codebook.
"""
import argparse
import json
import os
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def write(path, value):
    temporary = path.with_suffix('.tmp')
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--rules', action='store_true', help='Also download API key-code records for every unique remote index')
    args = parser.parse_args()
    import tinytuya
    credentials = json.loads((args.data / 'cloud.json').read_text())
    cloud = tinytuya.Cloud(**credentials)
    hub = json.loads((args.data / 'ir-detail.json').read_text())['result']['id']
    destination = args.data / 'hub-ac-inventory'
    destination.mkdir(mode=0o700, exist_ok=True)

    def get(name, endpoint, client=None):
        path = destination / (name + '.json')
        if path.exists():
            cached = json.loads(path.read_text())
            if cached.get('success') is True:
                return cached['result']
        result = (client or cloud)._tuyaplatform(endpoint, ver='v2.0')
        write(path, result)
        if result.get('success') is not True:
            raise RuntimeError('Tuya read rejected: code ' + str(result.get('code')))
        time.sleep(0.25)
        return result['result']

    base = 'infrareds/' + hub + '/categories/5'
    brands = get('brands', base + '/brands')
    inventory = []
    for position, brand in enumerate(brands, 1):
        brand_id = brand['brand_id']
        result = get('indexes-' + str(brand_id), base + '/brands/' + str(brand_id) + '/remote-indexs')
        indexes = result['remote_index_list']
        if len(indexes) != result['total_count']:
            raise RuntimeError('Incomplete remote index response; refusing to report full coverage')
        inventory.append(dict(brand, remote_indexes=[x['remote_index'] for x in indexes]))
        write(destination / 'inventory.json', {'complete': position == len(brands), 'brands': inventory})
        if position % 20 == 0 or position == len(brands):
            print('Brands: %d/%d; unique remote indexes: %d' %
                  (position, len(brands), len({i for b in inventory for i in b['remote_indexes']})), flush=True)
    if args.rules:
        owners = {}
        for brand in inventory:
            for index in brand['remote_indexes']:
                owners.setdefault(index, brand['brand_id'])
        report = []
        clients = threading.local()
        def read_rules(item):
            index, brand_id = item
            if not hasattr(clients, 'cloud'):
                clients.cloud = tinytuya.Cloud(**credentials)
            rules = get('rules-' + str(index), base + '/brands/' + str(brand_id) + '/remotes/' + str(index) + '/rules', clients.cloud)
            return {'remote_index': index, 'key_count': len(rules),
                    'nonempty_codes': sum(bool(k.get('code')) for k in rules)}
        with ThreadPoolExecutor(max_workers=3) as pool:
            for position, item in enumerate(pool.map(read_rules, owners.items()), 1):
                report.append(item)
                write(destination / 'rules-summary.json', {'complete': position == len(owners), 'remotes': report})
                if position % 20 == 0 or position == len(owners):
                    print('Code records: %d/%d' % (position, len(owners)), flush=True)


if __name__ == '__main__':
    main()
