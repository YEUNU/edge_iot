"""Short-lived enrollment tickets; long-lived bridge credentials stay on the LAN."""
import hashlib
import hmac
import json
import os
import time
from pathlib import Path

class PairingStore:
    def __init__(self, directory):
        self.directory = Path(directory)

    def redeem(self, ticket, device_id):
        if not isinstance(ticket,str) or len(ticket)!=64 or not isinstance(device_id,str):
            return False
        path=self.directory/'enrollment.json'
        try:
            record=json.loads(path.read_text())
            valid=(time.time() < record['expires_at'] and
                   hmac.compare_digest(record['device_id'],device_id) and
                   hmac.compare_digest(record['ticket_hash'],hashlib.sha256(ticket.encode()).hexdigest()))
            if not valid:return False
            # Consume durably before returning credentials, even across restarts.
            os.replace(path,self.directory/'enrollment.used.json')
            return True
        except (OSError,ValueError,KeyError,TypeError):
            return False
