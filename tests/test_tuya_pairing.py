import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tuya-local/bridge'))
from pairing import PairingStore

class PairingTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)
        self.ticket='a'*64;self.device='test-device';self.store=PairingStore(self.path)
        self.record={'ticket_hash':hashlib.sha256(self.ticket.encode()).hexdigest(),'device_id':self.device,'expires_at':time.time()+120}
        self.write()
    def write(self): (self.path/'enrollment.json').write_text(json.dumps(self.record))
    def tearDown(self):self.tmp.cleanup()
    def test_ticket_is_bound_to_device(self):
        self.assertFalse(self.store.redeem(self.ticket,'other-device'))
        self.assertTrue(self.store.redeem(self.ticket,self.device))
    def test_replay_fails_even_after_restart(self):
        self.assertTrue(self.store.redeem(self.ticket,self.device))
        self.assertFalse(PairingStore(self.path).redeem(self.ticket,self.device))
    def test_expired_and_wrong_ticket_fail(self):
        self.assertFalse(self.store.redeem('b'*64,self.device))
        self.record['expires_at']=time.time()-1;self.write()
        self.assertFalse(self.store.redeem(self.ticket,self.device))
    def test_closed_by_default(self):
        (self.path/'enrollment.json').unlink()
        self.assertFalse(self.store.redeem(self.ticket,self.device))


class PairingHttpTests(unittest.TestCase):
    def test_only_valid_one_time_ticket_returns_token(self):
        import threading
        from http.server import HTTPServer
        from http.client import HTTPConnection
        from service import Handler
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            ticket='c'*64
            record={'ticket_hash':hashlib.sha256(ticket.encode()).hexdigest(),'device_id':'owned-device','expires_at':time.time()+60}
            (Path(directory)/'enrollment.json').write_text(json.dumps(record))
            server=HTTPServer(('127.0.0.1',0),Handler)
            server.controller=SimpleNamespace(config={'api_token':'b'*64})
            server.pairing=PairingStore(directory)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            def request(body):
                c=HTTPConnection(*server.server_address,timeout=2)
                c.request('POST','/v1/pair',json.dumps(body),{'Content-Type':'application/json'})
                r=c.getresponse();result=r.status,json.loads(r.read());c.close();return result
            try:
                self.assertEqual(request({'ticket':ticket,'device_id':'other'})[0],403)
                code,body=request({'ticket':ticket,'device_id':'owned-device'})
                self.assertEqual(code,200);self.assertEqual(body['api_token'],'b'*64)
                self.assertEqual(request({'ticket':ticket,'device_id':'owned-device'})[0],403)
            finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
