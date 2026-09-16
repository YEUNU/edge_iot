#!/usr/bin/env python3
"""Convert a pinned community climate database to local Tuya head/key codebooks.

Only data is read. Unsupported encodings or lossy conversions are reported and
excluded; never silently claim compatibility. Runtime has no download path.
"""
import argparse
import base64
import gzip
import json
import math
from pathlib import Path

MODE = {'cool':'cool','heat':'heat','heat_cool':'auto','auto':'auto','dry':'dry','fan_only':'fanOnly'}
FAN = {'med':'medium','mid':'medium','middle':'medium'}


def pulses(code, controller):
    if controller == 'Broadlink':
        data = base64.b64decode(code, validate=True)
        if len(data) < 6 or data[0] != 0x26:
            raise ValueError('not a Broadlink IR packet')
        length = int.from_bytes(data[2:4], 'little')
        if len(data) < 4 + length:
            raise ValueError('truncated Broadlink packet')
        raw = data[4:4+length]
        values=[]; i=0
        while i < len(raw):
            value=raw[i]; i+=1
            if value == 0:
                if i+2 > len(raw): raise ValueError('truncated extended duration')
                value=int.from_bytes(raw[i:i+2],'big'); i+=2
            if not value: raise ValueError('zero pulse')
            values.append(math.ceil(value * 8192 / 269))
        values *= data[1]+1
    elif controller == 'ESPHome':
        values = [abs(int(v)) for v in (json.loads(code) if isinstance(code,str) else code)]
    elif controller == 'LOOKin':
        values = [abs(int(v)) for v in code.split()]
    else:
        raise ValueError('unsupported controller encoding: '+str(controller))
    if len(values) < 8 or any(v <= 0 for v in values):
        raise ValueError('invalid pulse train')
    if len(values) % 2: values.append(30000)
    return values


def convert_command(code, controller):
    from tinytuya.Contrib import IRRemoteControlDevice as IR
    source = pulses(code, controller)
    # Encode literal timing symbols: upstream bitfield encoder can overwrite
    # the first leader timing when assigning its third symbol.
    timings=[]; symbols=[]
    for duration in source:
        match=next((i for i,t in enumerate(timings) if abs(t-duration)<=max(15,duration*.035)),None)
        if match is None:
            match=len(timings);timings.append(duration)
        if match>=len(IR.KEY1_SYMBOL_LIST):raise ValueError('too many timing symbols')
        symbols.append(IR.KEY1_SYMBOL_LIST[match])
    while len(timings)<3:timings.append(100)
    head=IR.build_head(freq=38,bit_time_type=2,timings=timings)
    key='01'+''.join(symbols)
    decoded = IR.head_key_to_pulses(head,key)
    # TinyTuya merges timing clusters. Verify every duration and count before use.
    if len(decoded) != len(source) or any(abs(a-b) > max(35, a*.12) for a,b in zip(source,decoded)):
        raise ValueError('pulse round-trip outside tolerance')
    command={'control':'send_ir','type':0,'head':head,'key1':'0'+key}
    if len(json.dumps(command)) > 3072:
        raise ValueError('command exceeds hub DP size')
    return command


def convert_profile(data, index):
    if data.get('temperatureUnit','C') != 'C':
        raise ValueError('non-Celsius source')
    controller=data['supportedController']
    commands=data['commands']
    entries=[{'state':{'power':False},'command':convert_command(commands['off'],controller)}]
    skipped=0
    seen=set()
    for source_mode, fans in commands.items():
        if source_mode not in MODE or not isinstance(fans,dict): continue
        for fan, temps in fans.items():
            if not isinstance(temps,dict): continue
            # Some sources add swing -> temperature. Keep an explicit fixed
            # off/auto swing variant; do not invent independent swing commands.
            if temps and all(isinstance(v,dict) for v in temps.values()):
                swing=next((k for k in ('off','auto','Auto') if k in temps),sorted(temps)[0])
                temps=temps[swing]
            for temp, code in temps.items():
                try:
                    value=float(temp)
                    if not math.isfinite(value) or not -20 <= value <= 60: raise ValueError('temperature')
                    value=int(value) if value.is_integer() else value
                    state={'power':True,'mode':MODE[source_mode],'fan':FAN.get(fan.lower(),fan.lower()),'target_temperature':value}
                    key=(state['mode'],state['fan'],value)
                    if key in seen:continue
                    command=convert_command(code,controller)
                    entries.append({'state':state,'command':command});seen.add(key)
                except (ValueError,TypeError,KeyError,IndexError,OverflowError): skipped+=1
    if len(entries)<2:raise ValueError('no transferable on-state codes')
    default=next((e['state'] for e in entries if e['state'].get('mode')=='cool' and e['state'].get('fan')=='auto'),entries[1]['state'])
    models=data.get('supportedModels',[])
    return {'remote_index':index,'manufacturer':data['manufacturer'],
            'name':data['manufacturer']+' · '+', '.join(models)[:140]+' · '+str(index),
            'models':models,'default_state':{k:v for k,v in default.items() if k!='power'},
            'codes':entries,'excluded_states':skipped,'verification':'community codes; appliance test required'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    profiles=[];excluded=[]
    for file in sorted((args.source/'codes/climate').glob('*.json')):
        try:
            data=json.loads(file.read_text())
            result=convert_profile(data,int(file.stem))
            (args.output/(file.stem+'.json.gz')).write_bytes(gzip.compress(json.dumps(result,ensure_ascii=False,separators=(',',':')).encode(),mtime=0))
            profiles.append({k:v for k,v in result.items() if k not in ('codes','default_state')})
            print(file.stem,len(result['codes']),flush=True)
        except Exception as exc:
            excluded.append({'file':file.name,'reason':str(exc)[:160]})
    (args.output/'index.json').write_text(json.dumps({'profiles':profiles,'excluded':excluded},ensure_ascii=False,indent=2)+'\n')
    (args.output/'LICENSE.upstream').write_text((args.source/'LICENSE').read_text())
    print('Included',len(profiles),'Excluded',len(excluded),flush=True)


if __name__=='__main__':main()
