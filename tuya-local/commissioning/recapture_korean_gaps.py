#!/usr/bin/env python3
"""Recapture unresolved keys after the main export has finished.

Uses a separate exclusive journal per attempt and a five-second quiet interval
between responses and new requests. Never run alongside the primary exporter.
"""
import argparse
import fcntl
import json
import os
import time
from pathlib import Path
from export_korean_brands import plan, request_for


def unresolved(data):
    _, jobs = plan(data/'hub-ac-inventory')
    records = [json.loads(s) for s in (data/'korean-export-requests.jsonl').read_text().splitlines()]
    starts = {r['job'] for r in records if r['phase']=='start'}
    results = {r['job'] for r in records if r['phase']=='result'}
    if starts != set(range(len(jobs))) or results != starts:
        raise ValueError('The primary export must finish before recapturing gaps')
    for path in data.glob('korean-recapture-*.jsonl'):
        attempt = [json.loads(s) for s in path.read_text().splitlines()]
        began = {r['job'] for r in attempt if r['phase']=='start'}
        ended = {r['job'] for r in attempt if r['phase']=='result'}
        if began != ended:
            raise ValueError('Uncertain previous recapture requires inspection')
    report = json.loads((data/'korean-captured.json').read_text())
    missing = sorted({r['job'] for r in report['missing']})
    if any(n < 0 or n >= len(jobs) for n in missing):
        raise ValueError('Invalid gap report')
    return [(n, jobs[n]) for n in missing]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--send', action='store_true')
    parser.add_argument('--hub-covered', action='store_true')
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lock = os.open(args.data/'korean-export.lock', os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    jobs = unresolved(args.data)
    if args.limit: jobs=jobs[:args.limit]
    print('Unresolved keys:',len(jobs),flush=True)
    if not args.send or not jobs: return
    if not args.hub_covered: parser.error('--send requires --hub-covered')
    import tinytuya
    cloud = tinytuya.Cloud(**json.loads((args.data/'cloud.json').read_text()))
    hub = json.loads((args.data/'config.json').read_text())['device_id']
    path = args.data/('korean-recapture-%d.jsonl' % time.time_ns())
    with os.fdopen(os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as stream:
        def write(record):
            stream.write(json.dumps(record,ensure_ascii=False)+'\n')
            stream.flush();os.fsync(stream.fileno())
        for position,(number,job) in enumerate(jobs,1):
            endpoint,body=request_for(job)
            write(dict(job,job=number,phase='start',start_ms=int(time.time()*1000)))
            response=cloud._tuyaplatform('infrareds/'+hub+'/'+endpoint,action='POST',ver='v2.0',post=body)
            accepted=response.get('success') is True and response.get('result') is True
            write({'job':number,'phase':'result','accepted':accepted,'response_ms':response.get('t'),
                   'end_ms':int(time.time()*1000),'error_code':response.get('code'),
                   'error_message':response.get('msg')})
            print('%d/%d job=%d accepted=%s' % (position,len(jobs),number,accepted),flush=True)
            if not accepted: raise RuntimeError('Rejected key; inspect before another attempt')
            time.sleep(5)
            if position % 20 == 0:
                time.sleep(15)


if __name__=='__main__':main()
