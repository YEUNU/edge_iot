#!/usr/bin/env python3
"""One-time raw-key export for Samsung, LG, Carrier and Winia.

IR hub must be covered. This is not imported by the local runtime. Every request
is journaled before transmission, and an interrupted/uncertain request is not
silently retried. Raw Publish logs must subsequently be joined by timestamp.
"""
import argparse
import fcntl
import json
import math
import os
import re
import time
from pathlib import Path

BRANDS = {12: 'Samsung', 32: 'LG', 252: 'Carrier', 350: 'Winia'}


def plan(directory):
    inventory = json.loads((directory / 'inventory.json').read_text())
    if not inventory.get('complete'):
        raise ValueError('Incomplete inventory')
    brands = [b for b in inventory['brands'] if b['brand_id'] in BRANDS]
    if {b['brand_id'] for b in brands} != set(BRANDS):
        raise ValueError('Required brand missing')
    remotes = {}
    for brand in brands:
        for index in brand['remote_indexes']:
            remotes.setdefault(index, []).append(BRANDS[brand['brand_id']])
    jobs = []
    for index, owners in sorted(remotes.items()):
        response = json.loads((directory / ('rules-%s.json' % index)).read_text())
        if response.get('success') is not True or not response.get('result'):
            raise ValueError('Missing rules for index %s' % index)
        seen = set()
        for key in response['result']:
            identity = (key['key'], key['key_id'])
            if identity in seen:
                raise ValueError('Duplicate key for index %s' % index)
            seen.add(identity)
            jobs.append({'remote_index': index, 'brands': owners, 'key': key['key'],
                         'key_id': key['key_id'], 'key_name': key.get('key_name', key['key'])})
    return brands, jobs


def request_for(job):
    body = {'remote_index': job['remote_index'], 'category_id': 5}
    match = re.fullmatch(r'M(\d+)(?:_T(\d+))?(?:_S(\d+))?', job['key'])
    if match or job['key'] in ('power_on', 'power_off'):
        body['power'] = 0 if job['key'] == 'power_off' else 1
        if match:
            mode, temp, fan = match.groups()
            body['mode'] = int(mode)
            if temp is not None:
                body['temp'] = int(temp)
            if fan is not None:
                body['wind'] = int(fan)
        return 'air-conditioners/testing/scenes/command', body
    if not job['key_id']:
        raise ValueError('Non-state key has no reliable key ID')
    body.update(key=job['key'], key_id=job['key_id'])
    return 'testing/raw/command', body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--hub-covered', action='store_true')
    parser.add_argument('--send', action='store_true')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--interval', type=float, default=30,
                        help='Seconds of rest after each response (minimum 5; default 30)')
    args = parser.parse_args()
    if not math.isfinite(args.interval) or args.interval < 5:
        parser.error('--interval must be at least 5 seconds')
    brands, jobs = plan(args.data / 'hub-ac-inventory')
    print(json.dumps({'brands': {BRANDS[b['brand_id']]: len(b['remote_indexes']) for b in brands},
                      'unique_indexes': len({j['remote_index'] for j in jobs}), 'keys': len(jobs)}), flush=True)
    if not args.send:
        return
    if not args.hub_covered:
        parser.error('--send requires --hub-covered')
    import tinytuya
    cloud = tinytuya.Cloud(**json.loads((args.data / 'cloud.json').read_text()))
    hub = json.loads((args.data / 'config.json').read_text())['device_id']
    path = args.data / 'korean-export-requests.jsonl'
    lock = os.open(args.data/'korean-export.lock', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    records = [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []
    started = {r['job'] for r in records if r['phase'] == 'start'}
    completed = {r['job'] for r in records if r['phase'] == 'result'}
    if started != completed:
        raise RuntimeError('Uncertain previous request: inspect journal and Publish logs before resuming')
    count = 0
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), 'a') as stream:
        def record(value):
            stream.write(json.dumps(value, ensure_ascii=False) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        for number, job in enumerate(jobs):
            if number in completed:
                continue
            if args.limit and count >= args.limit:
                break
            began = time.time()
            record(dict(job, job=number, phase='start', start_ms=int(began * 1000)))
            endpoint, body = request_for(job)
            result = cloud._tuyaplatform('infrareds/' + hub + '/' + endpoint,
                action='POST', ver='v2.0', post=body)
            accepted = result.get('success') is True and result.get('result') is True
            record({'job': number, 'phase': 'result', 'accepted': accepted,
                    'response_ms': result.get('t'), 'end_ms': int(time.time()*1000),
                    'error_code': result.get('code'), 'error_message': result.get('msg')})
            count += 1
            print('%d/%d index=%s key=%s accepted=%s' %
                  (number+1, len(jobs), job['remote_index'], job['key'], accepted), flush=True)
            if not accepted:
                raise RuntimeError('Rejected key: stopped for inspection; no automatic retry')
            # Leave recovery time for the physical hub as well as distinct
            # console timestamp windows. Long one-second runs coincided with
            # the hub going offline; the cause is not yet established.
            now = time.time()
            time.sleep(math.ceil(now) + args.interval + 0.15 - now)
            if count % 20 == 0:
                time.sleep(15)


if __name__ == '__main__':
    main()
