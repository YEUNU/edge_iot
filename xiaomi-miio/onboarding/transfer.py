"""One-time, encrypted LAN transfer; reuses the driver's miIO packet codec.

The random 128-bit transfer key expires in 120 seconds. Only the selected hub
may claim the bundle. Xiaomi device tokens never appear in SmartThings commands.
"""
import hashlib
import hmac
import json
import secrets
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad


def encode(key, value):
    aes_key = hashlib.md5(key).digest()
    iv = hashlib.md5(aes_key + key).digest()
    payload = AES.new(aes_key, AES.MODE_CBC, iv).encrypt(pad(json.dumps(value).encode() + b'\0', 16))
    header = struct.pack('>HHIII', 0x2131, 32 + len(payload), 0, 1, int(time.time()))
    return header + hashlib.md5(header + key + payload).digest() + payload


def decode(key, raw):
    if len(raw) <= 32 or len(raw) > 16384 or raw[:2] != b'\x21\x31' or int.from_bytes(raw[2:4], 'big') != len(raw):
        raise ValueError('invalid packet')
    if not hmac.compare_digest(raw[16:32], hashlib.md5(raw[:16] + key + raw[32:]).digest()):
        raise ValueError('authentication failed')
    aes_key = hashlib.md5(key).digest()
    iv = hashlib.md5(aes_key + key).digest()
    return json.loads(unpad(AES.new(aes_key, AES.MODE_CBC, iv).decrypt(raw[32:]), 16).rstrip(b'\0'))


class Transfer:
    def __init__(self, address, hub, device_id, devices, ttl=120):
        self.key = secrets.token_bytes(16)
        self.device_id, self.devices = device_id, devices
        self.hub, self.deadline = hub, time.monotonic() + ttl
        self.claimed = False
        self.result = None
        self.done = threading.Event()
        self.lock = threading.Lock()
        transfer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.connection.settimeout(5)
                if self.client_address[0] != transfer.hub or time.monotonic() >= transfer.deadline:
                    self.send_error(403); return
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                    if not 32 < length <= 16384:
                        raise ValueError()
                    request = decode(transfer.key, self.rfile.read(length))
                    if request.get('device_id') != transfer.device_id:
                        raise ValueError()
                    with transfer.lock:
                        if self.path == '/bundle' and not transfer.claimed:
                            transfer.claimed = True
                            reply = {'device_id': transfer.device_id, 'devices': transfer.devices}
                        elif self.path == '/ack' and transfer.claimed and transfer.result is None:
                            result = request.get('result')
                            if not isinstance(result, dict):
                                raise ValueError()
                            transfer.result = result
                            reply = {'ok': True}
                        else:
                            raise ValueError()
                    body = encode(transfer.key, reply)
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    if self.path == '/ack':
                        transfer.done.set()
                except (ValueError, TypeError, KeyError, OSError):
                    self.send_error(400, 'Invalid or expired enrollment request')

        self.server = ThreadingHTTPServer((address, 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self.server.server_port

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.devices = []
        self.key = b''
