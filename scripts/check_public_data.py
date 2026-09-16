#!/usr/bin/env python3
"""Check publishable files without printing private values. Run before committing.

Complements a secret scanner: checks ignored runtime paths, home-directory paths,
and exact private identifiers/credentials found in local commissioning config.
"""
import argparse
import gzip
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_KEYS = {'local_key', 'api_token', 'apiKey', 'apiSecret', 'device_id',
                'deviceId', 'locationId', 'hubId', 'uid', 'owner_id',
                'access_token', 'refresh_token', 'client_secret', 'deviceToken'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def private_path(name):
    parts = Path(name).parts
    base = parts[-1]
    return (bool(set(parts) & {'data', 'state', '.state', '.venv', 'node_modules'})
            or (base.startswith('.env') and base not in {'.env.example', '.env.template'})
            or base in {'cloud.json', 'devices.json', 'tinytuya.json', 'secrets.json'}
            or Path(base).suffix in {'.pem', '.key', '.p12', '.pfx', '.har', '.pcap', '.pcapng', '.log'})


def local_private_values():
    result = set()
    def collect(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in PRIVATE_KEYS and isinstance(item, str) and len(item) >= 8:
                    result.add(item.encode())
                collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)
    names = git('ls-files', '--others', '--ignored', '--exclude-standard', '-z').decode().split('\0')
    for name in names:
        if Path(name).name not in {'config.json', 'cloud.json', 'credentials.json', 'ir-detail.json', 'ac-detail.json'}:
            continue
        try:
            collect(json.loads((ROOT / name).read_text()))
        except (OSError, ValueError, UnicodeError):
            pass
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Check the entire Git index instead of working files')
    args = parser.parse_args()
    names = git('ls-files', '-z') if args.staged else git('ls-files', '-co', '--exclude-standard', '-z')
    secrets = local_private_values()
    failures = []
    checked = 0
    for name in sorted(set(names.decode().split('\0')) - {''}):
        path = ROOT / name
        if not args.staged and not path.exists():
            continue
        if private_path(name):
            failures.append((name, 'private runtime/export path'))
            continue
        data = git('show', ':' + name) if args.staged else path.read_bytes()
        if name.endswith('.gz'):
            data = gzip.decompress(data)
        checked += 1
        if any(value in data for value in secrets):
            failures.append((name, 'known local private value'))
        if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', data):
            failures.append((name, 'personal home-directory path'))
    for name, reason in failures:
        print(name + ': ' + reason)
    print('%d files checked; %d privacy findings (values redacted)' % (checked, len(failures)))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
