#!/usr/bin/env python3
"""Supervise commissioning only: cool down, verify connectivity, resume safely.

No ambiguous request is retried. Offline-rejected keys remain journaled gaps
for later explicit recapture. Never imported by the cloud-free runtime.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from export_korean_brands import plan


def inspect_journal(path):
    records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    starts, results = {}, {}
    for record in records:
        if record['phase'] not in ('start', 'result'):
            raise ValueError('Unknown journal phase')
        target = starts if record['phase'] == 'start' else results
        if record['job'] in target:
            raise ValueError('Duplicate journal phase')
        target[record['job']] = record
    if starts.keys() != results.keys():
        raise ValueError('Uncertain request: manual inspection required')
    for result in results.values():
        if not result.get('accepted') and str(result.get('error_code')) != '30003':
            raise ValueError('Non-offline rejection: manual inspection required')
    latest = results[max(results)] if results else {}
    return len(results), latest


def cooldown_until(latest, now):
    if latest and not latest.get('accepted'):
        return latest['end_ms'] / 1000 + 15 * 60
    return now


def save(path, state):
    temp = path.with_suffix('.tmp')
    with os.fdopen(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as stream:
        json.dump(state, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--hub-covered', action='store_true')
    args = parser.parse_args()
    if not args.hub_covered:
        parser.error('IR emitter must remain shielded without enclosing the hub')
    data = args.data.resolve()
    lock = os.open(data/'korean-supervisor.lock', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    _, jobs = plan(data/'hub-ac-inventory')
    checkpoint = data/'korean-supervisor.json'
    state = json.loads(checkpoint.read_text()) if checkpoint.exists() else {'restarts': 0}
    config = json.loads((data/'config.json').read_text())
    import tinytuya
    cloud = tinytuya.Cloud(**json.loads((data/'cloud.json').read_text()))
    while True:
        count, latest = inspect_journal(data/'korean-export-requests.jsonl')
        if count == len(jobs):
            state['status'] = 'requests_complete_logs_and_gaps_pending'
            save(checkpoint, state)
            print(state['status'], flush=True)
            return
        if state['restarts'] >= 3:
            state['status'] = 'restart_limit_manual_review'
            save(checkpoint, state)
            raise RuntimeError('Three resume attempts used; manual review required')
        until = cooldown_until(latest, time.time())
        state.update(status='cooldown', cooldown_until=until)
        save(checkpoint, state)
        print('Waiting for cooldown and three stable connection checks', flush=True)
        while time.time() < until:
            time.sleep(min(30, until-time.time()))
        stable = 0
        while stable < 3:
            online = False
            try:
                with socket.create_connection((config['ip'], 6668), timeout=3):
                    pass
                result = cloud._tuyaplatform('devices/'+config['device_id'], action='GET')
                online = result.get('success') is True and result.get('result', {}).get('online') is True
            except Exception:
                pass
            stable = stable + 1 if online else 0
            state.update(status='checking_connection', stable_checks=stable)
            save(checkpoint, state)
            print('Stable connection checks: %d/3' % stable, flush=True)
            if stable < 3:
                time.sleep(60)
        state.update(status='exporting', restarts=state['restarts']+1)
        save(checkpoint, state)
        with open(data/'korean-supervised-export.log', 'a') as output:
            child = subprocess.run([sys.executable, str(Path(__file__).with_name('export_korean_brands.py')),
                '--data', str(data), '--send', '--hub-covered', '--interval', '5'],
                stdout=output, stderr=subprocess.STDOUT)
        new_count, last = inspect_journal(data/'korean-export-requests.jsonl')
        if child.returncode != 0 and (new_count <= count or last.get('accepted')):
            raise RuntimeError('Exporter stopped unexpectedly; manual inspection required')
        print('Exporter stopped; journal inspected', flush=True)


if __name__ == '__main__':
    main()
