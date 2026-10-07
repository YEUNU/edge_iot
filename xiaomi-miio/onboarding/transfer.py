"""One-time, encrypted LAN transfer; reuses the driver's miIO packet codec.

The random 128-bit transfer key expires in 120 seconds. Only the selected hub
may claim the bundle. Xiaomi device tokens never appear in SmartThings commands.
"""
import hashlib
import hmac
import json
import math
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
        if not isinstance(ttl, (int, float)) or isinstance(ttl, bool) or not 0 < ttl <= 120 or not math.isfinite(ttl):
            raise ValueError('transfer TTL must be between 0 and 120 seconds')
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
                acknowledged = False
                response_started = False
                try:
                    lengths = self.headers.get_all('Content-Length') if hasattr(self.headers, 'get_all') else [self.headers.get('Content-Length')]
                    if self.headers.get('Transfer-Encoding') is not None or not lengths or len(lengths) != 1:
                        raise ValueError()
                    value = str(lengths[0]).strip()
                    if not value.isascii() or not value.isdigit():
                        raise ValueError()
                    length = int(value)
                    if not 32 < length <= 16384:
                        raise ValueError()
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise ValueError()
                    request = decode(transfer.key, raw)
                    if not isinstance(request, dict) or request.get('device_id') != transfer.device_id:
                        raise ValueError()
                    with transfer.lock:
                        if time.monotonic() >= transfer.deadline:
                            raise ValueError()
                        if self.path == '/bundle' and not transfer.claimed:
                            transfer.claimed = True
                            reply = {'device_id': transfer.device_id, 'devices': transfer.devices,
                                     'expires_in': transfer.deadline - time.monotonic()}
                        elif self.path == '/ack' and transfer.claimed and transfer.result is None:
                            result = request.get('result')
                            counters = ('updated', 'requested', 'failed')
                            if not isinstance(result, dict) or set(result) != set(counters) or any(
                                type(result[name]) is not int or result[name] < 0 for name in counters
                            ) or sum(result.values()) != len(transfer.devices):
                                raise ValueError()
                            transfer.result = result
                            acknowledged = True
                            reply = {'ok': True}
                        else:
                            raise ValueError()
                    body = encode(transfer.key, reply)
                    response_started = True
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (ValueError, TypeError, KeyError, OSError):
                    if not response_started:
                        self.send_error(400, 'Invalid or expired enrollment request')
                finally:
                    # Receipt of a valid result is sufficient confirmation for
                    # the helper, even when the hub loses the HTTP reply.
                    if acknowledged:
                        transfer.done.set()

        self.server = ThreadingHTTPServer((address, 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.closed = False

    def start(self):
        with self.lock:
            if self.closed:
                raise RuntimeError('transfer already closed')
            if self.thread.ident is None:
                self.thread.start()
        return self.server.server_port

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            self.deadline = 0
        if self.thread.ident is not None:
            self.server.shutdown()
        self.server.server_close()
        if self.thread.ident is not None:
            self.thread.join(timeout=3)
        self.devices = []
        self.key = b''
