#!/usr/bin/env python3
"""One-time commissioning: emit Tuya's supported states for raw-log export.

The IR hub MUST be covered. Runtime service never imports or calls this tool.
Requires an explicit --hub-covered flag. Saves request timestamps so the console
Publish log can be joined unambiguously; restores initial cloud state at the end.
"""
import argparse
import json
import os
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--hub-covered', action='store_true', required=True)
    args = parser.parse_args()
    import tinytuya
    cloud = tinytuya.Cloud(**json.loads((args.data / 'cloud.json').read_text()))
    hub = json.loads((args.data / 'ir-detail.json').read_text())['result']['id']
    ac = json.loads((args.data / 'ac-detail.json').read_text())['result']['id']
    ranges = json.loads((args.data / 'keys.json').read_text())['result']['key_range']
    original = json.loads((args.data / 'ac-state.json').read_text())['result']
    endpoint = 'infrareds/%s/air-conditioners/%s/scenes/command' % (hub, ac)
    states = [{'power': 1, 'mode': m['mode'], 'temp': t['temp'], 'wind': f['fan']}
              for m in ranges for t in m['temp_list'] for f in t['fan_list']]
    output = args.data / 'export-requests.jsonl'
    if output.exists():
        raise SystemExit('Export already exists; inspect it before starting another run')
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        try:
            for index, state in enumerate(states):
                started = int(time.time() * 1000)
                result = cloud._tuyaplatform(endpoint, action='POST', post=state, ver='v2.0')
                if not result.get('success') or result.get('result') is not True:
                    raise RuntimeError('Cloud command rejected; export stopped')
                stream.write(json.dumps({'index':index, 'state':state, 'start_ms':started, 'response_ms':result['t']})+'\n')
                stream.flush()
                print('%d/%d %s' % (index+1,len(states),state), flush=True)
                time.sleep(3)
        finally:
            restored = {key:int(original[key]) for key in ('power','mode','temp','wind')}
            result = cloud._tuyaplatform(endpoint, action='POST', post=restored, ver='v2.0')
            print('Original cloud state restored:', result.get('success') and result.get('result'), flush=True)


if __name__ == '__main__':
    main()
