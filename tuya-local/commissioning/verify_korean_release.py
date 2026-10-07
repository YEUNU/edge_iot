#!/usr/bin/env python3
"""Fail closed unless all requested Tuya remotes and keys are installed."""
import argparse
import gzip
import importlib.util
import json
from pathlib import Path
import zlib
from build_korean_catalog import profile as build_profile


_spec = importlib.util.spec_from_file_location(
    '_release_controller', Path(__file__).resolve().parents[1]/'bridge/controller.py')
_controller = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_controller)


def read_json(path, compressed=False):
    try:
        raw = path.read_bytes()
        return json.loads(gzip.decompress(raw) if compressed else raw)
    except (OSError, ValueError, EOFError, zlib.error) as error:
        raise ValueError('Unreadable catalog file '+path.name) from error


def validate_runtime_profile(data, metadata, identifier, require_keys):
    if not isinstance(data, dict) or str(data.get('remote_index')) != identifier:
        raise ValueError('Remote identity mismatch in '+identifier)
    style = data.get('control_style', 'state')
    if style not in ('state', 'buttons') or metadata.get('control_style', 'state') != style:
        raise ValueError('Catalog control style disagrees in '+identifier)
    # Reuse the runtime parser, with public placeholders for connection settings.
    config = dict(data, ip='192.0.2.1', device_id='release-check', local_key='0'*16,
                  version=3.3, api_token='0'*32, control_type=1)
    try:
        _controller.validate(config)
        default = data.get('default_state')
        if not isinstance(default, dict):
            raise ValueError('default_state must be an object')
        if style == 'buttons':
            if data['codes'] or default:
                raise ValueError('button remote must not advertise absolute state')
        else:
            state = dict(default, power=True)
            key = _controller.state_key(state)
            if key not in {_controller.state_key(entry['state']) for entry in data['codes']}:
                raise ValueError('default_state must have a mapped code')
        if require_keys:
            original = build_profile(int(identifier), [
                {'key': key['id'], 'command': key['command'], 'brands': data['brands']}
                for key in data['keys']])
            def code_pairs(entries):
                return {(_controller.state_key(entry['state']),
                         json.dumps(entry['command'], sort_keys=True, allow_nan=False))
                        for entry in entries}
            if style != original['control_style'] or code_pairs(data['codes']) != code_pairs(original['codes']):
                raise ValueError('state mapping differs from captured key payloads')
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        raise ValueError('Invalid runtime profile in '+identifier+': '+str(error)) from error


def verify(catalog, scope, require_existing=False):
    index = read_json(catalog/'index.json')
    profiles = index.get('profiles') if isinstance(index, dict) else None
    if (not isinstance(profiles, list) or any(not isinstance(p, dict)
            or type(p.get('remote_index')) is not int or p['remote_index'] < 1 for p in profiles)):
        raise ValueError('Invalid catalog index')
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
    for identifier in by_id:
        data = read_json(catalog/(identifier+'.json.gz'), compressed=True)
        validate_runtime_profile(data, by_id[identifier], identifier, identifier in expected)
        if identifier not in expected:
            continue
        keys = expected[identifier]
        actual = [key['id'] for key in data.get('keys', [])]
        if len(actual) != len(set(actual)) or set(actual) != set(keys):
            raise ValueError('Missing, duplicate or unexpected keys in remote '+identifier)
        aliases = data.get('brands')
        index_aliases = by_id[identifier].get('brands')
        if (not isinstance(aliases, list) or not all(isinstance(brand, str) for brand in aliases)
                or set(aliases) != brands_by_id[identifier]):
            raise ValueError('Brand aliases missing for remote '+identifier)
        if (not isinstance(index_aliases, list) or not all(isinstance(brand, str) for brand in index_aliases)
                or set(index_aliases) != brands_by_id[identifier]
                or not isinstance(by_id[identifier].get('manufacturer'), str)
                or by_id[identifier].get('manufacturer') not in brands_by_id[identifier]):
            raise ValueError('Catalog index brand aliases disagree for remote '+identifier)
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
