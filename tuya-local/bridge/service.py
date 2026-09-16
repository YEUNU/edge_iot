#!/usr/bin/env python3
"""Local authenticated HTTP bridge and read-only commissioning tools."""
import argparse
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from controller import Controller, DeviceError
from pairing import PairingStore


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Do not log paths, request bodies, or credentials.

    def reply(self, status, data):
        body = json.dumps(data, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def authorized(self):
        supplied = self.headers.get('Authorization', '').encode()
        expected = ('Bearer ' + self.server.controller.config['api_token']).encode()
        if not hmac.compare_digest(supplied, expected):
            self.reply(401, {'error': 'unauthorized'})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path != '/v1/state':
            self.reply(404, {'error': 'not found'})
            return
        self.run_device(lambda: self.server.controller.status(self.headers.get('X-IR-Profile')))

    def do_POST(self):
        if self.path == '/v1/pair':
            return self.pair()
        if not self.authorized():
            return
        if self.path != '/v1/command':
            self.reply(404, {'error': 'not found'})
            return
        try:
            if self.headers.get('Transfer-Encoding'):
                raise ValueError('chunked requests unsupported')
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 2048:
                raise ValueError('invalid body length')
            changes = json.loads(self.rfile.read(size))
        except (ValueError, OSError):
            self.reply(400, {'error': 'invalid JSON body or length'})
            return
        self.run_device(lambda: self.server.controller.command(changes, self.headers.get('X-IR-Profile')))

    def pair(self):
        try:
            size=int(self.headers.get('Content-Length','0'))
            if self.headers.get('Transfer-Encoding') or not 0<size<=512:raise ValueError()
            request=json.loads(self.rfile.read(size))
            store=getattr(self.server,'pairing',None)
            if not store or not store.redeem(request.get('ticket'),request.get('device_id')):
                self.reply(403,{'error':'enrollment unavailable'});return
            self.reply(200,{'api_token':self.server.controller.config['api_token']})
        except (ValueError,AttributeError,OSError):
            self.reply(400,{'error':'invalid enrollment request'})

    def run_device(self, operation):
        try:
            self.reply(200, operation())
        except ValueError as exc:
            self.reply(400, {'error': str(exc)})
        except DeviceError as exc:
            self.reply(502, {'error': str(exc)})
        except Exception:
            self.reply(502, {'error': 'device communication failed'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['scan', 'inspect', 'check', 'serve'])
    parser.add_argument('--config', default='/data/config.json')
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8766)
    parser.add_argument('--state-dir', default='/state')
    args = parser.parse_args()
    if args.action == 'scan':
        import tinytuya
        found = tinytuya.deviceScan(verbose=False, maxretry=5, poll=False)
        print(json.dumps([{k: d.get(k) for k in ('ip', 'gwId', 'version')} for d in found.values()], indent=2))
        return
    config_path = Path(args.config)
    if os.name == 'posix' and config_path.stat().st_mode & 0o077:
        parser.error('config contains secrets: chmod 600 ' + str(config_path))
    config = json.loads(config_path.read_text())
    from local_network import restrict_to_hub
    restrict_to_hub(config['ip'])
    if args.action == 'inspect':
        # Does not require a guessed mapping and never sends a control command.
        import tinytuya
        device = tinytuya.Device(config['device_id'], config['ip'], config['local_key'],
                                version=config['version'], connection_timeout=3, connection_retry_limit=1)
        try:
            result = device.status()
            if not isinstance(result, dict) or 'Err' in result or 'dps' not in result:
                raise DeviceError('LAN read failed; verify connection settings')
            print(json.dumps({'dps': result['dps']}, indent=2))
        finally:
            device.close()
        return
    if args.action=='serve':config['settings_path']=str(Path(args.state_dir)/'settings.json')
    controller = Controller(config)
    if args.action == 'check':
        print(json.dumps(controller.status(), indent=2))
    else:
        server = HTTPServer((args.bind, args.port), Handler)
        server.controller = controller
        server.pairing = PairingStore(args.state_dir)
        print('Tuya LAN bridge listening on %s:%d' % server.server_address, flush=True)
        try:
            server.serve_forever()
        finally:
            server.server_close()
            controller.device.close()


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, DeviceError, OSError):
        raise SystemExit('Configuration or LAN operation failed; verify config and use inspect/check.')
