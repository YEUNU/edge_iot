#!/usr/bin/env python3
"""Join private console Publish rows to unambiguous accepted request windows.

A successful API response alone is never considered a captured IR code. Missing,
ambiguous, rejected or oversized signals remain explicit coverage gaps.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
from zoneinfo import ZoneInfo
from export_korean_brands import plan, read_request_journal


def join(journal, rows, timezone='Asia/Seoul'):
    starts, results, logs = {}, {}, {}
    for record in journal:
        if not isinstance(record, dict) or record.get('phase') not in ('start', 'result'):
            raise ValueError('Unknown request journal phase')
        if type(record.get('job')) is not int or record['job'] < 0:
            raise ValueError('Invalid request journal job')
        if record['phase'] == 'result' and type(record.get('accepted')) is not bool:
            raise ValueError('Invalid request journal acceptance')
        if record['phase'] == 'result' and record['job'] not in starts:
            raise ValueError('Journal result has no preceding request')
        target = starts if record['phase'] == 'start' else results
        if record['job'] in target:
            raise ValueError('Duplicate request journal phase')
        target[record['job']] = record
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('command'), dict) or row['command'].get('control') != 'send_ir':
            continue
        key = row['time']
        serialized = json.dumps(row['command'], sort_keys=True)
        logs.setdefault(key, {})[serialized] = row['command']
    # Publish occurs before the API response and can cross a second boundary.
    # Only accept a log second attributable to exactly one request interval.
    windows, owners, epoch_seconds = {}, {}, {}
    def valid_stamp(value):
        return type(value) in (int, float) and 0 <= value <= 253402300799999
    for number, request in starts.items():
        response = results.get(number, {})
        if not response.get('accepted') or not response.get('response_ms'):
            continue
        stamp = response['response_ms']
        began, ended = request.get('start_ms', stamp), response.get('end_ms', stamp)
        if not all(valid_stamp(value) for value in (stamp, began, ended)):
            continue
        if ended < began or ended-began > 10000 or abs(ended-stamp) > 2000:
            continue
        seconds = []
        for value in range(int(min(began,stamp)//1000), int(max(ended,stamp)//1000)+1):
            second = datetime.datetime.fromtimestamp(value, ZoneInfo(timezone)).strftime('%Y-%m-%d %H:%M:%S')
            seconds.append(second)
            owners.setdefault(second, set()).add(number)
            epoch_seconds[second] = value
        windows[number] = seconds
    # An uncertain send can still have emitted IR. Its known interval must
    # compete with accepted requests for attribution; absence of a result is
    # never evidence that a nearby Publish belongs to another command.
    for number, request in starts.items():
        if number in windows:
            continue
        response = results.get(number, {})
        stamp = response.get('response_ms')
        began = request.get('start_ms', stamp)
        ended = response.get('end_ms', stamp)
        if not valid_stamp(began):
            for candidates in owners.values():
                candidates.add(number)
            continue
        lower = int(began // 1000)
        upper = int(ended // 1000) if valid_stamp(ended) and ended >= began else None
        if valid_stamp(stamp):
            lower = min(lower, int(stamp // 1000))
            if upper is not None:upper = max(upper, int(stamp // 1000))
        for second, value in epoch_seconds.items():
            if value >= lower and (upper is None or value <= upper):
                owners[second].add(number)
    captured, missing = [], []
    claimed = set()
    for number, request in sorted(starts.items()):
        response = results.get(number, {})
        if not response.get('accepted') or not response.get('response_ms'):
            missing.append({'job': number, 'reason': 'unaccepted_or_uncertain'})
            continue
        matches = [(second, logs[second]) for second in windows.get(number, [])
                   if second in logs and len(owners[second]) == 1]
        if len(matches) != 1 or len(matches[0][1]) != 1 or matches[0][0] in claimed:
            missing.append({'job': number, 'reason': 'missing_or_ambiguous_publish'})
            continue
        second, candidates = matches[0]
        command = next(iter(candidates.values()))
        if (type(command.get('type')) is not int or command['type'] != 0 or not isinstance(command.get('head'), str)
                or not command['head'] or not isinstance(command.get('key1'), str)
                or not command['key1'] or len(json.dumps(command)) > 3072):
            missing.append({'job': number, 'reason': 'unsupported_payload'})
            continue
        claimed.add(second)
        captured.append({k: v for k, v in request.items() if k not in ('phase', 'start_ms')} | {'command': command})
    return {'captured': captured, 'missing': missing}


def merge_results(results):
    captured, missing, conflicts = {}, {}, set()
    for result in results:
        for item in result['missing']:
            missing[item['job']] = item
        for item in result['captured']:
            number = item['job']
            if number in captured and any(captured[number].get(k) != item.get(k)
                    for k in ('remote_index', 'brands', 'key', 'key_id', 'command')):
                conflicts.add(number)
            captured[number] = item
    for number in conflicts:
        captured.pop(number, None)
        missing[number] = {'job': number, 'reason': 'conflicting_captures'}
    return {'captured': [captured[n] for n in sorted(captured)],
            'missing': [missing[n] for n in sorted(missing) if n not in captured]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    args = parser.parse_args()
    _,jobs=plan(args.data/'hub-ac-inventory')
    def validated_records(path, contiguous):
        starts,results=read_request_journal(path,jobs,contiguous=contiguous,complete=False)
        return [record for number in sorted(starts)
                for record in (starts[number],results.get(number)) if record is not None]
    journal = validated_records(args.data/'korean-export-requests.jsonl',True)
    rows = []
    for path in sorted(args.data.glob('korean-console-*.json')):
        rows.extend(json.loads(path.read_text()))
    joined = [join(journal, rows)]
    for path in sorted(args.data.glob('korean-recapture-*.jsonl')):
        attempt = validated_records(path,False)
        joined.append(join(attempt, rows))
    result = merge_results(joined)
    target = args.data/'korean-captured.json'
    with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    print('Matched:', len(result['captured']), 'Pending:', len(result['missing']))


if __name__ == '__main__':
    main()
