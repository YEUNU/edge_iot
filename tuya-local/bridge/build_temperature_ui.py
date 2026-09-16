"""Generate bounded native controls while preserving standard automation capabilities."""
import gzip,json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
profiles=json.loads((root/'bridge/catalog/index.json').read_text())['profiles']
ranges={};by_id={}
for p in profiles:
 data=json.loads(gzip.decompress((root/'bridge/catalog'/(str(p['remote_index'])+'.json.gz')).read_bytes()))
 temps=sorted({e['state']['target_temperature'] for e in data['codes'] if e['state']['power']})
 lo,hi=min(temps),max(temps)
 slug='acTemp'+str(lo)+'To'+str(hi)
 ranges[slug]=(lo,hi);by_id[str(p['remote_index'])]=slug
base=(root/'profiles/tuya-local-ac.yml').read_text()
base=re.sub(r'\nmetadata:[\s\S]*','',base)
basecfg=json.loads((root/'device-configs/tuya-local-ac.json').read_text())
for slug,(lo,hi) in ranges.items():
 cap={'name':'AC Temp '+str(lo)+' To '+str(hi),'attributes':{
  'temperature':{'schema':{'type':'object','properties':{'value':{'type':'number','minimum':lo,'maximum':hi},'unit':{'type':'string','enum':['C'],'default':'C'}},'required':['value'],'additionalProperties':False},'setter':'setTemperature'},
  'temperatureRange':{'schema':{'type':'object','properties':{'value':{'type':'object','properties':{'minimum':{'type':'number'},'maximum':{'type':'number'},'step':{'type':'number'}},'required':['minimum','maximum','step'],'additionalProperties':False}},'required':['value'],'additionalProperties':False}}
 },'commands':{'setTemperature':{'name':'setTemperature','arguments':[{'name':'temperature','optional':False,'schema':{'type':'number','minimum':lo,'maximum':hi}}]}}}
 presentation={'dashboard':{'states':[],'actions':[]},'detailView':[{'label':'설정 온도','displayType':'slider','slider':{'value':'temperature.value','unit':'temperature.unit','command':'setTemperature','range':[lo,hi],'step':1,'supportedValues':'temperatureRange.value'}}],'automation':{'conditions':[],'actions':[]}}
 for name,obj in [(slug+'.json',cap),(slug+'-presentation.json',presentation)]:
  (root/'capabilities'/name).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
 name='tuya-local-ac.'+slug+'.v1'
 text=base.replace('name: tuya-local-ac.v1','name: '+name).replace('      - id: thermostatCoolingSetpoint','      - id: earthpanel38939.'+slug+'\n        version: 1\n      - id: thermostatCoolingSetpoint')
 profile_path=root/'profiles'/('tuya-local-'+slug+'.yml')
 if profile_path.exists():
  existing=profile_path.read_text()
  if '\nmetadata:' in existing:text+='\nmetadata:'+existing.split('\nmetadata:',1)[1]
 profile_path.write_text(text)
 cfg=json.loads(json.dumps(basecfg))
 for row in cfg['detailView']:
  if row['capability']=='thermostatCoolingSetpoint':row['capability']='earthpanel38939.'+slug;row['patch']=[]
 (root/'device-configs'/('tuya-local-'+slug+'.json')).write_text(json.dumps(cfg,ensure_ascii=False,indent=2)+'\n')
lines=['return {','  by_id={']
for id,slug in by_id.items():lines.append('    ["'+id+'"]="'+slug+'",')
lines+=['  },','  types={']
for slug in sorted(ranges):lines.append('    "'+slug+'",')
lines+=['  }','}']
(root/'src/temperature_profiles.lua').write_text('\n'.join(lines)+'\n')
print(len(ranges),'bounded temperature profiles')
