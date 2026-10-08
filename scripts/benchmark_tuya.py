#!/usr/bin/env python3
"""Measure public-catalog retention and mocked Tuya UI polls; never sends IR.

Compare checkouts with --source-root. Timings and heap sizes are host measurements,
not SmartThings hub, mobile-app or IR-device performance measurements.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import tracemalloc


class MockHub:
    def __init__(self, *args, **kwargs):
        pass

    def set_socketPersistent(self, *args):
        pass

    def set_socketRetryLimit(self, *args):
        pass

    def set_multiple_values(self, *args, **kwargs):
        return None

    def status(self):
        return {'dps': {}}

    def close(self):
        pass


def catalog_metrics(source_root, iterations):
    source = source_root / 'tuya-local' / 'bridge' / 'controller.py'
    spec = importlib.util.spec_from_file_location('benchmark_tuya_controller', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    config = {'ip': '192.0.2.2', 'device_id': 'benchmark-id', 'local_key': '0' * 16,
              'version': 3.3, 'api_token': 'a' * 64, 'remote_index': 104800501,
              'control_type': 1, 'catalog_dir': str(source.parent / 'catalog')}
    tracemalloc.start()
    controller = module.Controller(config, factory=MockHub)
    initial_bytes = tracemalloc.get_traced_memory()[0]
    largest_snapshot = 0
    largest_codes = (0, None)
    for profile_id in controller.catalog:
        controller._select(profile_id)
        largest_snapshot = max(largest_snapshot, len(json.dumps(controller._snapshot()).encode()))
        size = len(controller.codes)
        if size > largest_codes[0]:
            largest_codes = (size, profile_id)
    retained_bytes, peak_bytes = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    retained_profiles = len(controller.profiles)
    controller._select(largest_codes[1])
    started = time.perf_counter()
    for _ in range(iterations):
        controller._snapshot()
    snapshot_us = (time.perf_counter() - started) * 1_000_000 / iterations
    return {'visited_profiles': len(controller.catalog), 'retained_profiles': retained_profiles,
            'initial_heap_bytes': initial_bytes, 'retained_heap_bytes': retained_bytes,
            'peak_heap_bytes': peak_bytes, 'largest_snapshot_bytes': largest_snapshot,
            'largest_code_count': largest_codes[0], 'snapshot_us': round(snapshot_us, 3)}


LUA_POLLS = r"""
package.path=arg[1]..'/tuya-local/src/?.lua;'..package.path
local driver
package.preload['st.driver']=function() return function(_,d)
 driver=d;return {run=function()end}
end end
local caps=setmetatable({}, {__index=function(t,id)
 local c={ID=id,commands=setmetatable({}, {__index=function(_,key)return{NAME=key}end})}
 setmetatable(c,{__index=function(_,key)return function(value)
  return {cap=id,attr=key,value=value}
 end end});rawset(t,id,c);return c
end})
package.preload['st.capabilities']=function()return caps end
local reads=0
package.preload.client=function()return{
 valid=function()return true end,
 request=function(p)
  reads=reads+1
  return {state={power=true,mode='cool',fan='auto',target_temperature=24},
   settings={mode='cool',fan='auto',target_temperature=24},
   profile_id=tostring(p.remoteIndex),supported_modes={'cool','heat'},
   supported_fans={'auto','high'},temperature={min=18,max=30,step=1},supported_keys={}}
 end
}end
require 'init'
local fields={active_profile='104800501',setup_closed=true}
local events,presence=0,0
local d={preferences={bridgeIp='192.0.2.2',bridgePort=8766,bridgeToken='benchmark'},
 thread={call_on_schedule=function()return 1 end},log={warn=function()end}}
function d:get_field(key)return fields[key]end
function d:set_field(key,value)fields[key]=value end
function d:try_update_metadata()end
function d:supports_capability(c)
 return fields.setup_open or (c.ID~='earthpanel38939.acModelLibrary' and c.ID~='earthpanel38939.acRemoteKeys')
end
function d:emit_event()events=events+1 end
function d:online()presence=presence+1 end
function d:offline()end
driver.lifecycle_handlers.init(nil,d)
events,reads,presence=0,0,0
for _=1,10 do driver.capability_handlers.refresh.refresh(nil,d)end
print('daily_events='..events)
print('daily_health_reads='..reads)
print('daily_presence_calls='..presence)
fields.setup_open=true
driver.capability_handlers.refresh.refresh(nil,d)
events,reads=0,0
for _=1,10 do driver.capability_handlers.refresh.refresh(nil,d)end
print('setup_events='..events)
print('setup_health_reads='..reads)
"""


def poll_metrics(source_root):
    result = subprocess.run(['lua', '-', str(source_root)], input=LUA_POLLS, text=True,
                            capture_output=True, check=True, timeout=30)
    return {key: int(value) for key, value in
            (line.split('=', 1) for line in result.stdout.splitlines())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--iterations', type=int, default=5000)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error('--iterations must be positive')
    source_root = args.source_root.resolve()
    print(json.dumps({'source_root': str(source_root),
                      'catalog': catalog_metrics(source_root, args.iterations),
                      'ten_unchanged_polls': poll_metrics(source_root)}, indent=2))


if __name__ == '__main__':
    main()
