#!/usr/bin/env python3
"""Publish native UI definitions to the authenticated SmartThings account."""
import json
from pathlib import Path
import subprocess
import sys
import time
ROOT=Path(__file__).resolve().parents[1]
NAMESPACE='earthpanel38939'

def normalized_presentation(value):
    if isinstance(value,list):
        return [normalized_presentation(item) for item in value]
    if isinstance(value,dict):
        return {key:normalized_presentation(item) for key,item in value.items()
                if not (key=='panelItems' and item==[])
                and not (key=='type' and item=='active')
                and not (key=='valueType' and item=='string')}
    return value

def invoke(*args):
    for attempt in range(3):
        result=subprocess.run(['smartthings',*args,'-j'],text=True,capture_output=True)
        if not result.returncode or 'status 403' not in result.stderr or '4040000' in result.stderr:
            return result
        if attempt<2:time.sleep(2)
    return result

def run(*args):
    result=invoke(*args)
    if result.returncode:raise RuntimeError(result.stderr or result.stdout)
    return json.loads(result.stdout)

def main():
    subprocess.run([sys.executable, str(ROOT/'commissioning/verify_korean_release.py'),
                    str(ROOT/'bridge/catalog'), '--require-existing'], check=True)
    caps=[ROOT/'capabilities/acLocalLink.json',ROOT/'capabilities/acModelLibrary.json',ROOT/'capabilities/acModeControl.json',ROOT/'capabilities/acRemoteKeys.json']
    caps+=sorted(p for p in (ROOT/'capabilities').glob('acTemp*.json') if not p.name.endswith('-presentation.json'))
    for path in caps:
        identifier=NAMESPACE+'.'+path.stem
        probe=invoke('capabilities',identifier)
        if probe.returncode and not any(code in probe.stderr for code in ('status 404','4040000')):
            raise RuntimeError('Capability lookup failed; refusing to assume absence: '+probe.stderr)
        if probe.returncode:run('capabilities:create','-n',NAMESPACE,'-i',str(path))
        else:run('capabilities:update',identifier,'-i',str(path))
        presentation_probe=invoke('capabilities:presentation',identifier)
        if presentation_probe.returncode and not any(code in presentation_probe.stderr for code in ('status 404','4040000')):
            raise RuntimeError('Presentation lookup failed; refusing to assume absence: '+presentation_probe.stderr)
        operation='capabilities:presentation:create' if presentation_probe.returncode else 'capabilities:presentation:update'
        presentation_path=path.with_name(path.stem+'-presentation.json')
        desired=json.loads(presentation_path.read_text())
        current=json.loads(presentation_probe.stdout) if not presentation_probe.returncode else None
        if current is not None:
            current={k:v for k,v in current.items() if k not in ('id','version')}
        if normalized_presentation(current)!=normalized_presentation(desired):
            run(operation,identifier,'-i',str(presentation_path))
        print(identifier)
    for path in sorted((ROOT/'translations').glob('*.ko.json')):
        run('capabilities:translations:upsert',NAMESPACE+'.'+path.name.removesuffix('.ko.json'),'-i',str(path))
    for cfg in sorted((ROOT/'device-configs').glob('*.json')):
        profile=ROOT/'profiles'/(cfg.stem+'.yml')
        if not profile.exists():raise ValueError('Missing profile: '+str(profile))
        data=run('presentation:device-config:create','-i',str(cfg))
        body=profile.read_text().split('\nmetadata:',1)[0]
        profile.write_text(body+'\nmetadata:\n  mnmn: SmartThingsCommunity\n  vid: '+data['presentationId']+'\n')
        print(profile.name)
if __name__=='__main__':main()
