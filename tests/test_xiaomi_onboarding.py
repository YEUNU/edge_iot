import json
from pathlib import Path
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'xiaomi-miio/onboarding'))
from transfer import Transfer, encode, decode
from onboard import normalize


class OnboardingTests(unittest.TestCase):
    def test_codec_and_tampering(self):
        key = b'A'*16
        raw = encode(key, {'devices':[{'token':'not a household secret'}]})
        self.assertEqual(decode(key,raw)['devices'][0]['token'],'not a household secret')
        with self.assertRaises(ValueError): decode(key,raw[:-1]+bytes([raw[-1]^1]))
        with self.assertRaises(ValueError): decode(b'B'*16,raw)

    def test_normalize_deduplicate_filter(self):
        record={'did':'123','localip':'192.168.1.2','token':'ab'*16,'model':'zhimi.fan.za5'}
        self.assertEqual(len(normalize([record,record])),1)
        for change in [{'token':'0'*32},{'localip':'127.0.0.1'},{'model':'unsupported'},{'did':'no'}]:
            self.assertEqual(normalize([{**record,**change}]),[])

    def test_transfer_expiry_and_single_use(self):
        t=Transfer('127.0.0.1','127.0.0.1','setup',[{'did':123}])
        port=t.start()
        def post(path,key=None):
            data=encode(key or t.key,{'device_id':'setup'})
            return urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=data),timeout=3)
        try:
            with self.assertRaises(urllib.error.HTTPError): post('/bundle',b'B'*16)
            response=decode(t.key,post('/bundle').read())
            self.assertEqual(response['devices'],[{'did':123}])
            with self.assertRaises(urllib.error.HTTPError): post('/bundle')
            t.deadline=time.monotonic()-1
            with self.assertRaises(urllib.error.HTTPError): post('/ack')
        finally: t.close()

    def test_actual_lua_transport_and_import(self):
        t=Transfer('127.0.0.1','127.0.0.1','setup',[{'did':123,'ip':'192.168.1.2','token':'ab'*16,'model':'zhimi.fan.za5'}])
        port=t.start()
        # Transport uses loopback only in the fixture; production rejects it.
        script=r'''
package.path = "xiaomi-miio/src/?.lua;" .. package.path
package.preload["cosock.socket"] = function() return require "socket" end
package.preload["st.json"] = function() return require "dkjson" end
package.preload.log = function() return {info=function()end,warn=function()end,error=function()end} end
local json = require "dkjson"
local args=json.decode(io.read("*a"))
local connection=require "connection"
local valid=connection.valid_ip
connection.valid_ip=function(ip) return ip=="127.0.0.1" or valid(ip) end
local Client=require "miio.client"
Client.new=function() return {handshake=function()return 123 end,miio_info=function()return {model="zhimi.fan.za5"} end} end
local driver={datastore={},get_devices=function()return {} end}
local created=0
function driver:try_create_device(metadata) assert(metadata.model=="zhimi.fan.za5");created=created+1;return true end
local status
require("enrollment").handle(driver,{id="setup",model="xiaomi.setup"},args,function(s)status=s end)
assert(created==1, status)
assert(driver.datastore["discovered:xiaomi-miio-123"].token==string.rep("ab",16))
assert(driver.xiaomi_enrolling==false)
print("LUA_IMPORT_OK")
'''
        try:
            proc=subprocess.run(['lua','-e',script],input=json.dumps({'address':'127.0.0.1','port':port,'ticket':t.key.hex()}),capture_output=True,text=True,cwd=ROOT,timeout=10)
            self.assertEqual(proc.returncode,0,proc.stderr)
            self.assertEqual(t.result,{'updated':0,'requested':1,'failed':0})
            self.assertTrue(t.done.wait(1))
        finally:t.close()

if __name__=='__main__':unittest.main()
