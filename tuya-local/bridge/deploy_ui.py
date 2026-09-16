#!/usr/bin/env python3
"""Publish native UI definitions to the authenticated SmartThings account."""
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
NAMESPACE='earthpanel38939'

def run(*args):
    result=subprocess.run(['smartthings',*args,'-j'],text=True,capture_output=True)
    if result.returncode:raise RuntimeError(result.stderr or result.stdout)
    return json.loads(result.stdout)

def main():
    caps=[ROOT/'capabilities/acLocalLink.json',ROOT/'capabilities/acModelLibrary.json',ROOT/'capabilities/acModeControl.json']
    caps+=sorted(p for p in (ROOT/'capabilities').glob('acTemp*.json') if not p.name.endswith('-presentation.json'))
    for path in caps:
        identifier=NAMESPACE+'.'+path.stem
        probe=subprocess.run(['smartthings','capabilities',identifier,'-j'],capture_output=True)
        if probe.returncode:run('capabilities:create','-n',NAMESPACE,'-i',str(path))
        else:run('capabilities:update',identifier,'-i',str(path))
        presentation_probe=subprocess.run(['smartthings','capabilities:presentation',identifier,'-j'],capture_output=True)
        operation='capabilities:presentation:create' if presentation_probe.returncode else 'capabilities:presentation:update'
        run(operation,identifier,'-i',str(path.with_name(path.stem+'-presentation.json')))
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
