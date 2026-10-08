#!/usr/bin/env python3
"""Measure TLS configuration initialization locally; never connect to a server."""
import argparse
import http.client
import importlib.util
import json
from pathlib import Path
import statistics
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations',type=int,default=100)
    parser.add_argument('--repeats',type=int,default=5)
    args=parser.parse_args()
    if args.iterations<=0 or args.repeats<=0:
        parser.error('iterations and repeats must be positive')
    root=Path(__file__).resolve().parents[1]
    spec=importlib.util.spec_from_file_location('notifier_benchmark',root/'notification-service/notifier.py')
    notifier=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(notifier)
    result={}
    for name,context in [('default_context_per_connection',None),('reused_verified_context',notifier.HTTPS_CONTEXT)]:
        samples=[]
        for _ in range(args.repeats):
            began=time.perf_counter()
            for _ in range(args.iterations):
                connection=http.client.HTTPSConnection('unused.example.test',context=context)
                connection.close()  # Construction opens no socket.
            samples.append((time.perf_counter()-began)*1000/args.iterations)
        result[name+'_median_ms']=statistics.median(samples)
    result['scope']='host TLS configuration initialization; no network or handshake latency measured'
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
