"""Short-lived enrollment tickets; long-lived bridge credentials stay on the LAN."""
import hashlib
import hmac
import fcntl
import json
import os
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

class PairingStore:
    def __init__(self, directory):
        self.directory = Path(directory)

    @contextmanager
    def locked(self):
        with (self.directory/'enrollment.lock').open('a') as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    @staticmethod
    def read(path):
        try:
            record=json.loads(path.read_text())
            return record if isinstance(record,dict) else {}
        except (OSError,ValueError,RecursionError):
            return {}

    @staticmethod
    def matches(record, ticket, device_id):
        if not isinstance(ticket,str) or len(ticket)!=64 or not isinstance(device_id,str):
            return False
        try:
            return (hmac.compare_digest(record['device_id'],device_id) and
                    hmac.compare_digest(record['ticket_hash'],hashlib.sha256(ticket.encode('ascii')).hexdigest()))
        except (ValueError,KeyError,TypeError):
            return False

    def publish(self, record):
        with self.locked():
            fd,temp=tempfile.mkstemp(dir=self.directory,prefix='.enrollment-')
            try:
                with os.fdopen(fd,'w') as stream:
                    json.dump(record,stream)
                    stream.flush();os.fsync(stream.fileno())
                os.replace(temp,self.directory/'enrollment.json')
            finally:
                if os.path.exists(temp):os.unlink(temp)

    def redeemed(self, ticket, device_id):
        with self.locked():
            return self.matches(self.read(self.directory/'enrollment.used.json'),ticket,device_id)

    def revoke(self, ticket, device_id):
        with self.locked():
            path=self.directory/'enrollment.json'
            if self.matches(self.read(path),ticket,device_id):
                path.unlink(missing_ok=True)

    def redeem(self, ticket, device_id):
        path=self.directory/'enrollment.json'
        try:
            with self.locked():
                record=self.read(path)
                expiry=record.get('expires_at')
                if (type(expiry) not in (int,float) or not 0 <= expiry <= 253402300799
                        or not time.time() < expiry or not self.matches(record,ticket,device_id)):
                    return False
                # Serialize validation and consumption with CLI publication.
                os.replace(path,self.directory/'enrollment.used.json')
                return True
        except (OSError,ValueError,KeyError,TypeError):
            return False
