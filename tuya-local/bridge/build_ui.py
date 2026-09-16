"""Build native SmartThings selectors from the installed offline catalogue."""
import gzip,json
from pathlib import Path
root=Path(__file__).resolve().parents[1];directory=root/'bridge/catalog'
x=json.loads((directory/'index.json').read_text())
carrier=json.loads(gzip.decompress((directory/'104800501.json.gz').read_bytes()))
if not any(p['remote_index']==104800501 for p in x['profiles']):
 x['profiles'].append({k:v for k,v in carrier.items() if k not in ('codes','default_state')})
x['source']={'url':'https://github.com/smartHomeHub/SmartIR','commit':'e4df2957ad915536f41ffb39daa96886d7cfe040','license':'MIT','carrier':'Tuya user-authorized export, 107 on states + off'}
(directory/'index.json').write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n')
profiles=sorted(x['profiles'],key=lambda p:(p['manufacturer'],p['remote_index']))
brands=sorted({p['manufacturer'] for p in profiles})
def attr(kind='string'):
 value={'type':kind}
 if kind=='array':value['items']={'type':'string'}
 return {'schema':{'type':'object','properties':{'value':value},'required':['value'],'additionalProperties':False}}
cap={'name':'AC Model Library','attributes':{k:attr() for k in ['brand','candidate','status']},'commands':{}}
cap['attributes']['supportedCandidates']=attr('array')
cap['attributes']['brand']['setter']='setBrand'
cap['attributes']['brand']['schema']['properties']['value']['enum']=brands
cap['attributes']['candidate']['setter']='setCandidate'
cap['attributes']['candidate']['schema']['properties']['value']['enum']=[p['name'] for p in profiles]
for command,arg in [('setBrand','brand'),('setCandidate','candidate'),('applyCode',None)]:
 cap['commands'][command]={'name':command,'arguments':([{'name':arg,'optional':False,'schema':{'type':'string'}}] if arg else [])}
for attribute,command in [('brand','setBrand'),('candidate','setCandidate')]:
 cap['commands'][command]['arguments'][0]['schema']['enum']=cap['attributes'][attribute]['schema']['properties']['value'].pop('enum')
presentation={'dashboard':{'states':[],'actions':[],'panelItems':[]},'detailView':[],'automation':{'conditions':[],'actions':[]}}
def model_label(p):
 if p['remote_index']==104800501:return '기존 Carrier 리모컨'
 models=', '.join(p.get('models',[]))[:65]
 return (models if models and models!='Unknown' else '호환 코드')+' · '+str(p['remote_index'])
for attribute,label,values,command in [('brand','제조사',[{'key':b,'value':b} for b in brands],'setBrand'),('candidate','기종',[{'key':p['name'],'value':model_label(p)} for p in profiles],'setCandidate')]:
 model={'command':{'name':command,'alternatives':values,'argumentType':'string'},'state':{'value':attribute+'.value','alternatives':values}}
 if attribute=='candidate':model['command']['supportedValues']='supportedCandidates.value'
 presentation['detailView'].append({'label':label,'displayType':'list','list':model})
for command,label in [('applyCode','반응 확인 · 기종 저장')]:
 presentation['detailView'].append({'label':label,'displayType':'pushButton','pushButton':{'command':command}})
for attribute,label in [('status','설정 안내')]:
 presentation['detailView'].append({'label':label,'displayType':'state','state':{'label':'{{'+attribute+'.value}}'}})
for name,obj in [('acModelLibrary.json',cap),('acModelLibrary-presentation.json',presentation)]:
 (root/'capabilities'/name).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
# Lua quoted strings use JSON-compatible escaping for these labels.
lines=['return {']
for p in profiles:lines.append('  [%s]={brand=%s,name=%s},'%(json.dumps(str(p['remote_index'])),json.dumps(p['manufacturer'],ensure_ascii=False),json.dumps(p['name'],ensure_ascii=False)))
(root/'src/catalog.lua').write_text('\n'.join(lines+['}'])+'\n')
print(len(profiles),'code sets;',len(brands),'brands')
