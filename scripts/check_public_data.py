#!/usr/bin/env python3
"""Check publishable files against local private configuration without printing values.

Complements a secret scanner; optionally check reachable commit email metadata.
"""
import argparse
import gzip
import ipaddress
import json
import re
import subprocess
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Normalize camelCase, snake_case and environment-variable spellings.
PRIVATE_KEYS = {
    'localkey', 'apitoken', 'apikey', 'apisecret', 'deviceid', 'locationid',
    'hubid', 'uid', 'ownerid', 'accesstoken', 'refreshtoken', 'clientsecret',
    'devicetoken', 'token', 'did', 'homeid', 'householdid', 'accountid',
    'password', 'passwd', 'email', 'username', 'testdeviceid', 'parentdeviceid',
}
ADDRESS_KEYS = {'ip', 'localip', 'bindip', 'mac', 'macaddress'}
ID_CONTAINERS = {'devices', 'locations', 'hubs', 'homes', 'households', 'owners'}
CONFIG_NAMES = {
    'config.json', 'cloud.json', 'credentials.json', 'auth.json', 'devices.json',
    'tinytuya.json', 'secrets.json', 'known_hubs.json', 'ir-detail.json', 'ac-detail.json',
}
SKIP_SOURCE_DIRS = {'.state', '.venv', 'venv', 'node_modules', 'tests', 'fixtures'}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, stderr=subprocess.DEVNULL)


def private_path(name):
    parts = Path(name).parts
    base = parts[-1]
    return (bool(set(parts) & {'data', 'state', '.state', '.venv', 'node_modules'})
            or (base.startswith('.env') and base not in {'.env.example', '.env.template'})
            or base in CONFIG_NAMES - {'config.json'}
            or Path(base).suffix in {'.pem', '.key', '.p12', '.pfx', '.har', '.pcap', '.pcapng', '.log'})


def normalized(key):
    return re.sub('[^a-z0-9]', '', key.lower())


def environment_value(value):
    if value.startswith(('"', "'")):
        quote = value[0]
        match = re.fullmatch(re.escape(quote) + r'(.*?)' + re.escape(quote) + r'(?:\s*#.*)?', value)
        if not match:
            raise ValueError('invalid quoted environment value')
        return match.group(1)
    return re.split(r'\s+#', value, maxsplit=1)[0].strip()


def add_private_value(result, key, value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return
    value = str(value).strip()
    if key in {'ip', 'localip', 'bindip'}:
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            return
        if address.is_loopback or address.is_unspecified:
            return
        result.add(value.encode())
    elif key in {'mac', 'macaddress'}:
        compact = re.sub('[:-]', '', value)
        if re.fullmatch('[0-9a-fA-F]{12}', compact):
            for separator in ('', ':', '-'):
                variant = separator.join(compact[i:i + 2] for i in range(0, 12, 2))
                result.update({variant.lower().encode(), variant.upper().encode()})
    elif len(value) >= (6 if value.isdigit() else 8):
        result.add(value.encode())


def collect_private_values(value, result, context=''):
    if isinstance(value, dict):
        for key, item in value.items():
            field = normalized(key)
            if field in PRIVATE_KEYS | ADDRESS_KEYS or (field == 'id' and context in ID_CONTAINERS):
                add_private_value(result, field, item)
            collect_private_values(item, result, field)
    elif isinstance(value, list):
        for item in value:
            collect_private_values(item, result, context)


def default_private_configs():
    support = Path.home() / 'Library/Application Support'
    return [support / '@smartthings/cli' / name for name in ('credentials.json', 'known_hubs.json')] + [
        support / 'Xiaomi Notifications' / name for name in ('auth.json', 'config.json')]


def local_private_values(extra_configs=()):
    result, failures = set(), []
    names = git('ls-files', '--others', '--ignored', '--exclude-standard', '-z').decode().split('\0')
    sources = []
    for name in filter(None, names):
        path = Path(name)
        # Audit reports and synthetic fixtures are not authoritative runtime config.
        if set(path.parts) & SKIP_SOURCE_DIRS:
            continue
        if path.name in CONFIG_NAMES or (path.name.startswith('.env') and private_path(name)):
            sources.append((ROOT / path, name, False))
    sources.extend((path, 'default private config #%d' % i, True)
                   for i, path in enumerate(default_private_configs(), 1))
    sources.extend((Path(path).expanduser(), 'explicit private config #%d' % i, False)
                   for i, path in enumerate(extra_configs, 1))
    for path, label, optional in sources:
        try:
            content = path.read_text()
            if path.name.startswith('.env'):
                for line in content.splitlines():
                    match = re.match(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$', line)
                    if match:
                        key, value = match.groups()
                        # Environment variables can have a provider prefix, e.g. TUYA_BIND_IP.
                        fields = [normalized(key)] + [normalized(key.split('_', i)[-1])
                                                     for i in range(1, len(key.split('_')))]
                        field = next((part for part in fields if part in PRIVATE_KEYS | ADDRESS_KEYS), None)
                        if field:
                            add_private_value(result, field, environment_value(value))
            else:
                payload = json.loads(content)
                collect_private_values(payload, result, 'devices' if path.name in {'devices.json', 'tinytuya.json'} else '')
                if path.name == 'known_hubs.json' and isinstance(payload, dict):
                    for endpoint in payload:
                        # The CLI stores LAN addresses as map keys, with a port suffix.
                        host = endpoint.rsplit(':', 1)[0] if ':' in endpoint else endpoint
                        add_private_value(result, 'ip', host.strip('[]'))
        except FileNotFoundError:
            if not optional:
                failures.append((label, 'private comparison source is missing'))
        except (OSError, ValueError, UnicodeError):
            failures.append((label, 'cannot read private comparison source'))
    return result, failures


def contains_private_value(data, values):
    for value in values:
        # Do not mistake a DID or IP prefix inside a longer number/address for a match.
        if value.isdigit():
            if re.search(rb'(?<![A-Za-z0-9])' + re.escape(value) + rb'(?![A-Za-z0-9])', data):
                return True
        elif re.fullmatch(rb'(?:\d{1,3}\.){3}\d{1,3}', value):
            if re.search(rb'(?<![\d.])' + re.escape(value) + rb'(?![\d.])', data):
                return True
        elif value in data:
            return True
    return False


def metadata_findings():
    findings = []
    for line in git('log', '--all', '--format=%H%x00%ae%x00%ce').decode().splitlines():
        commit, author, committer = line.split('\0')
        if any(not re.fullmatch(r'(?:[^@]+@users\.noreply\.github\.com|noreply@github\.com)', email)
               for email in (author, committer)):
            findings.append(('commit ' + commit[:12], 'non-noreply author/committer email'))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Check the entire Git index instead of working files')
    parser.add_argument('--private-config', action='append', default=[], metavar='PATH',
                        help='Also compare against this private JSON or .env file (repeatable)')
    parser.add_argument('--metadata', action='store_true', help='Check author/committer emails in all reachable commits')
    args = parser.parse_args()
    failures, checked = [], 0
    try:
        names = git('ls-files', '-z') if args.staged else git('ls-files', '-co', '--exclude-standard', '-z')
        secrets, source_failures = local_private_values(args.private_config)
        failures.extend(source_failures)
        for name in sorted(set(names.decode().split('\0')) - {''}):
            path = ROOT / name
            try:
                if args.staged:
                    data = git('show', ':' + name)
                else:
                    # Git publishes a symlink's target text, not the external file contents.
                    data = str(path.readlink()).encode() if path.is_symlink() else path.read_bytes()
                if private_path(name):
                    failures.append((name, 'private runtime/export path'))
                    continue
                if name.endswith('.gz'):
                    data = gzip.decompress(data)
            except FileNotFoundError:
                # A deleted working file will not be published; --staged still reads its index blob.
                continue
            except (OSError, EOFError, zlib.error, subprocess.CalledProcessError):
                failures.append((name, 'cannot read/decompress publishable file'))
                continue
            checked += 1
            if contains_private_value(data, secrets):
                failures.append((name, 'known local private value'))
            if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', data):
                failures.append((name, 'personal home-directory path'))
        if args.metadata:
            failures.extend(metadata_findings())
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
        failures.append(('scan', 'cannot complete Git/config inspection'))
    for name, reason in failures:
        print(name + ': ' + reason)
    print('%d files checked; %d privacy findings (values redacted)' % (checked, len(failures)))
    raise SystemExit(int(bool(failures)))


if __name__ == '__main__':
    main()
