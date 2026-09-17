#!/usr/bin/env python3
"""Fail closed unless all requested Tuya remotes and keys are installed."""
import argparse
import gzip
import json
from pathlib import Path


def verify(catalog, scope, require_existing=False):
    index = json.loads((catalog/'index.json').read_text())
    profiles = index['profiles']
    by_id = {str(p['remote_index']): p for p in profiles}
    if len(by_id) != len(profiles):
        raise ValueError('Duplicate remote index')
    if require_existing and '104800501' not in by_id:
        raise ValueError('Existing working Carrier remote must be preserved')
    expected = scope['keys_by_remote']
    extras = set(by_id)-set(expected)-{'104800501'}
    if extras:
        raise ValueError('Non-Tuya or out-of-scope remotes remain')
    missing = set(expected)-set(by_id)
    if missing:
        raise ValueError('%d requested remotes are still missing' % len(missing))
    files = {p.name.removesuffix('.json.gz') for p in catalog.glob('*.json.gz')}
    if files != set(by_id):
        raise ValueError('Catalog files and index disagree')
    brands_by_id = {}
    for brand in scope['brands']:
        for identifier in brand['remote_indexes']:
            brands_by_id.setdefault(str(identifier), set()).add(brand['name'])
    keys_count = 0
    for identifier, keys in expected.items():
        data = json.loads(gzip.decompress((catalog/(identifier+'.json.gz')).read_bytes()))
        if str(data.get('remote_index')) != identifier:
            raise ValueError('Remote identity mismatch in '+identifier)
        actual = [key['id'] for key in data.get('keys', [])]
        if len(actual) != len(set(actual)) or set(actual) != set(keys):
            raise ValueError('Missing, duplicate or unexpected keys in remote '+identifier)
        if set(data.get('brands', [])) != brands_by_id[identifier]:
            raise ValueError('Brand aliases missing for remote '+identifier)
        if (set(by_id[identifier].get('brands', [])) != brands_by_id[identifier]
                or by_id[identifier].get('manufacturer') not in brands_by_id[identifier]):
            raise ValueError('Catalog index brand aliases disagree for remote '+identifier)
        for key in data['keys']:
            command = key['command']
            if (command.get('control') != 'send_ir' or command.get('type') != 0
                    or not command.get('head') or not command.get('key1')
                    or len(json.dumps(command)) > 3072):
                raise ValueError('Invalid local payload in remote '+identifier)
        keys_count += len(actual)
    if len(expected) != scope['unique_indexes'] or keys_count != scope['expected_keys']:
        raise ValueError('Coverage totals disagree with the requested scope')
    return {'remote_indexes': len(expected), 'keys': keys_count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('catalog', type=Path)
    parser.add_argument('--require-existing', action='store_true')
    args = parser.parse_args()
    scope = json.loads(Path(__file__).with_name('KOREAN_SCOPE.json').read_text())
    try:
        result = verify(args.catalog, scope, args.require_existing)
    except ValueError as error:
        parser.exit(1, 'NOT READY: '+str(error)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
