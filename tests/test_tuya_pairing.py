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

    def test_revoke_only_removes_its_own_ticket_and_receipt_is_bound(self):
        self.store.revoke('b'*64,self.device)
        self.assertTrue((self.path/'enrollment.json').exists())
        self.assertFalse(self.store.redeemed(self.ticket,self.device))
        self.assertTrue(self.store.redeem(self.ticket,self.device))
        self.assertTrue(self.store.redeemed(self.ticket,self.device))
        self.assertFalse(self.store.redeemed('b'*64,self.device))
        self.assertFalse(self.store.redeemed(self.ticket,'other'))
        self.write()
        self.store.revoke(self.ticket,self.device)
        self.assertFalse((self.path/'enrollment.json').exists())

    def test_publish_cannot_replace_record_during_validation_and_consume(self):
        import threading
        from unittest.mock import patch
        read_done=threading.Event(); release=threading.Event(); published=threading.Event()
        new_record=dict(self.record,ticket_hash=hashlib.sha256(('b'*64).encode()).hexdigest())
        original_read=self.store.read
        def blocked_read(path):
            record=original_read(path)
            read_done.set()
            self.assertTrue(release.wait(2))
            return record
        outcome=[]
        with patch.object(self.store,'read',side_effect=blocked_read):
            reader=threading.Thread(target=lambda:outcome.append(self.store.redeem(self.ticket,self.device)))
            reader.start()
            self.assertTrue(read_done.wait(2))
            def publish():
                PairingStore(self.path).publish(new_record)
                published.set()
            writer=threading.Thread(target=publish);writer.start()
            try:
                self.assertFalse(published.wait(0.05))
            finally:
                release.set();reader.join(2);writer.join(2)
        self.assertFalse(reader.is_alive());self.assertFalse(writer.is_alive())
        self.assertEqual(outcome,[True])
        self.assertEqual(json.loads((self.path/'enrollment.used.json').read_text()),self.record)
        self.assertEqual(json.loads((self.path/'enrollment.json').read_text()),new_record)

    def test_two_consumers_cannot_redeem_same_ticket(self):
        import threading
        gate=threading.Barrier(3);outcome=[]
        def redeem():
            gate.wait()
            outcome.append(PairingStore(self.path).redeem(self.ticket,self.device))
        workers=[threading.Thread(target=redeem) for _ in range(2)]
        for worker in workers:worker.start()
        gate.wait()
        for worker in workers:worker.join(2);self.assertFalse(worker.is_alive())
        self.assertEqual(sorted(outcome),[False,True])

    def test_invalid_expiry_or_shape_fails_closed(self):
        for value in (True,'1000',float('inf'),float('nan'),10**1000):
            self.record['expires_at']=value;self.write()
            with self.subTest(value=value):self.assertFalse(self.store.redeem(self.ticket,self.device))
        (self.path/'enrollment.json').write_text('[]')
        self.assertFalse(self.store.redeem(self.ticket,self.device))


class ConnectOwnershipTests(unittest.TestCase):
    def setUp(self):
        from types import SimpleNamespace
        self.tmp=tempfile.TemporaryDirectory()
        self.path=Path(self.tmp.name)
        self.args=SimpleNamespace(state_dir=self.path,device='owned-device',address='192.0.2.1',port=8766)
    def tearDown(self):self.tmp.cleanup()

    def test_dispatch_waits_for_its_own_redemption_receipt(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        import connect_smartthings as connect
        def dispatch(command,**kwargs):
            request=json.loads(Path(command[-1]).read_text())
            self.assertTrue(PairingStore(self.path).redeem(request['arguments'][2],self.args.device))
            return SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch.object(connect.subprocess,'run',side_effect=dispatch), patch('builtins.print') as output:
            connect.dispatch_enrollment(self.args)
        self.assertIn('redeemed',output.call_args[0][0])

    def test_missing_ticket_is_not_a_successful_redemption(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        import connect_smartthings as connect
        def dispatch(*args,**kwargs):
            (self.path/'enrollment.json').unlink()
            return SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch.object(connect.subprocess,'run',side_effect=dispatch), \
             patch.object(connect.time,'monotonic',side_effect=[0,0,36]), \
             patch.object(connect.time,'sleep'), patch('builtins.print') as output:
            with self.assertRaisesRegex(SystemExit,'not redeemed'):connect.dispatch_enrollment(self.args)
        output.assert_not_called()

    def test_overlapping_dispatch_does_not_overwrite_first_ticket(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        import connect_smartthings as connect
        def dispatch(command,**kwargs):
            first=(self.path/'enrollment.json').read_text()
            with self.assertRaisesRegex(SystemExit,'Another enrollment'):
                connect.dispatch_enrollment(self.args)
            self.assertEqual((self.path/'enrollment.json').read_text(),first)
            return SimpleNamespace(returncode=1,stdout='',stderr='rejected')
        with patch.object(connect.subprocess,'run',side_effect=dispatch):
            with self.assertRaisesRegex(SystemExit,'dispatch failed'):connect.dispatch_enrollment(self.args)
        self.assertFalse((self.path/'enrollment.json').exists())

    def test_command_file_failure_revokes_ticket_before_any_dispatch(self):
        from unittest.mock import patch
        import connect_smartthings as connect
        original=connect.tempfile.mkstemp
        def fail_command_file(*args,**kwargs):
            if kwargs.get('prefix')=='ir-enroll-':raise OSError('disk full')
            return original(*args,**kwargs)
        with patch.object(connect.tempfile,'mkstemp',side_effect=fail_command_file), \
             patch.object(connect.subprocess,'run') as dispatch:
            with self.assertRaises(OSError):connect.dispatch_enrollment(self.args)
        dispatch.assert_not_called()
        self.assertFalse((self.path/'enrollment.json').exists())


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
