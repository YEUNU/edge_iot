"""Native button-remote view; controls never pretend to know absolute AC state."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
NS='earthpanel38939.'

def write(path, value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')

def attribute(kind):
    value={'type':kind}
    if kind=='array': value['items']={'type':'string'}
    return {'schema':{'type':'object','properties':{'value':value},'required':['value'],'additionalProperties':False}}

cap={'name':'AC Remote Keys','attributes':{'key':attribute('string'),'supportedKeys':attribute('array')},
     'commands':{'selectKey':{'name':'selectKey','arguments':[{'name':'key','optional':False,'schema':{'type':'string'}}]},
                 'sendKey':{'name':'sendKey','arguments':[]},'back':{'name':'back','arguments':[]}}}
cap['attributes']['key']['setter']='selectKey'
presentation={'dashboard':{'states':[],'actions':[]},'detailView':[
 {'label':'리모컨 버튼','displayType':'list','list':{'command':{'name':'selectKey','supportedValues':'supportedKeys.value','argumentType':'string'},'state':{'value':'key.value'}}},
 {'label':'선택한 버튼 보내기','displayType':'pushButton','pushButton':{'command':'sendKey'}},
 {'label':'돌아가기','displayType':'pushButton','pushButton':{'command':'back'}}],
 'automation':{'conditions':[],'actions':[]}}
keys=json.loads((ROOT/'commissioning/KOREAN_KEYS.json').read_text())
alternatives=[{'key':key,'value':label} for key,label in sorted(keys.items())]
presentation['detailView'][0]['list']['command']['alternatives']=alternatives
presentation['detailView'][0]['list']['state']['alternatives']=alternatives
write(ROOT/'capabilities/acRemoteKeys.json',cap)
write(ROOT/'capabilities/acRemoteKeys-presentation.json',presentation)
link=json.loads((ROOT/'capabilities/acLocalLink.json').read_text())
link['commands']['showKeys']={'name':'showKeys','arguments':[]}
write(ROOT/'capabilities/acLocalLink.json',link)
linkp=json.loads((ROOT/'capabilities/acLocalLink-presentation.json').read_text())
linkp['detailView']=[r for r in linkp['detailView'] if r.get('pushButton',{}).get('command')!='showKeys']
linkp['detailView'].append({'label':'리모컨 버튼 더보기','displayType':'pushButton','pushButton':{'command':'showKeys'}})
write(ROOT/'capabilities/acLocalLink-presentation.json',linkp)

def row(cap, patch=None):
    return {'component':'main','capability':cap,'version':1,'values':[],'patch':patch or []}

for suffix in ('keys','buttons','setup-buttons'):
    capabilities=[NS+'acRemoteKeys',NS+'acLocalLink','refresh']
    if suffix=='setup-buttons': capabilities.insert(0,NS+'acModelLibrary')
    text='name: tuya-local-ac.'+suffix+'.v1\ncomponents:\n  - id: main\n    capabilities:\n'
    for c in capabilities: text+='      - id: '+c+'\n        version: 1\n'
    text+='    categories:\n      - name: AirConditioner\n'
    profile=ROOT/'profiles'/('tuya-local-ac-'+suffix+'.yml')
    if profile.exists() and '\nmetadata:' in profile.read_text():
        text+='\nmetadata:'+profile.read_text().split('\nmetadata:',1)[1]
    profile.write_text(text)
    rawpatch=[] if suffix=='keys' else [{'op':'remove','path':'/2'}]
    detail=[row(NS+'acRemoteKeys',rawpatch)]
    if suffix=='setup-buttons':
        detail.insert(0,row(NS+'acModelLibrary'))
        linkpatch=[{'op':'remove','path':'/2'},{'op':'remove','path':'/1'},
                   {'op':'replace','path':'/0','value':{'label':'변경 취소','displayType':'pushButton','pushButton':{'command':'done'}}}]
    else:
        linkpatch=[{'op':'remove','path':'/2'}]
        if suffix=='keys':linkpatch.append({'op':'remove','path':'/1'})
    detail.append(row(NS+'acLocalLink',linkpatch))
    write(ROOT/'device-configs'/('tuya-local-ac-'+suffix+'.json'),{'type':'profile','dashboard':{'states':[row(NS+'acLocalLink')],'actions':[]},'detailView':detail,'automation':{'conditions':[],'actions':[]}})
# Connection screen must not offer a remote command before enrollment.
p=ROOT/'device-configs/tuya-local-ac-connect.json'; cfg=json.loads(p.read_text())
for r in cfg['detailView']:
    if r['capability']==NS+'acLocalLink':r['patch']=[{'op':'remove','path':'/2'},{'op':'remove','path':'/1'}]
write(p,cfg)
