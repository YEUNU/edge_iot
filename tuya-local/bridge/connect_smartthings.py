#!/usr/bin/env python3
"""Enroll an existing SmartThings device without manually copying a bearer token.

The CLI delivers a 120-second, single-use ticket over the existing authenticated
SmartThings account. The hub exchanges it on the LAN, persists the bridge token,
and reconnects locally thereafter. Tokens are never included in CLI commands.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import ipaddress
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device')
    parser.add_argument('--address')
    parser.add_argument('--port',type=int,default=8766)
    parser.add_argument('--state-dir',type=Path,default=Path(__file__).parent/'state')
    args=parser.parse_args()
    if not args.device:
        result=subprocess.run(['smartthings','devices','-j'],capture_output=True,text=True,check=True)
        candidates=[d for d in json.loads(result.stdout) if d.get('deviceManufacturerCode')=='Tuya' and d.get('lan') and d.get('name','').startswith('tuya-local-ac')]
        if len(candidates)!=1:parser.error('Specify --device when there is not exactly one Tuya local AC device.')
        args.device=candidates[0]['deviceId']
    if not args.address:
        env=Path(__file__).parent/'.env'
        if env.exists():
            args.address=next((line.partition('=')[2].strip() for line in env.read_text().splitlines() if line.startswith('TUYA_BIND_IP=')),None)
        if not args.address or args.address in ('127.0.0.1','0.0.0.0'):
            parser.error('Set TUYA_BIND_IP in bridge/.env or supply --address with the LAN address.')
    uuid.UUID(args.device);ipaddress.IPv4Address(args.address)
    if not 0<args.port<=65535:parser.error('invalid port')
    args.state_dir.mkdir(mode=0o700,parents=True,exist_ok=True)
    ticket=secrets.token_hex(32)
    record={'ticket_hash':hashlib.sha256(ticket.encode()).hexdigest(),'device_id':args.device,'expires_at':time.time()+120}
    path=args.state_dir/'enrollment.json'
    fd,tmp=tempfile.mkstemp(dir=args.state_dir,prefix='.enrollment-')
    with os.fdopen(fd,'w') as out:json.dump(record,out)
    os.replace(tmp,path)
    commands=[{'component':'main','capability':'earthpanel38939.acLocalLink','command':'enroll','arguments':[args.address,args.port,ticket]}]
    fd,tmp=tempfile.mkstemp(prefix='ir-enroll-',suffix='.json')
    try:
        with os.fdopen(fd,'w') as out:json.dump(commands[0],out)
        result=subprocess.run(['smartthings','devices:commands',args.device,'-i',tmp],capture_output=True,text=True)
        if result.returncode:
            raise SystemExit('SmartThings enrollment dispatch failed: '+(result.stderr or result.stdout).replace(ticket,'[redacted]')[:1200])
        deadline=time.monotonic()+35
        while time.monotonic()<deadline:
            if not path.exists():
                print('Enrollment ticket redeemed by hub. Verify device connection status.');return
            time.sleep(1)
        raise SystemExit('Ticket not redeemed. Check driver update and LAN address, then retry.')
    finally:
        os.unlink(tmp)
        # Unconsumed tickets are revoked on failure, not left waiting on the LAN.
        path.unlink(missing_ok=True)

if __name__=='__main__':main()
