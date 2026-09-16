#!/usr/bin/env python3
"""QR login once, then import credentials into the SmartThings hub over LAN.

No password prompt, no credential export, no background service after enrollment.
"""
import argparse
import importlib.util
import ipaddress
import json
import logging
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from transfer import Transfer

SUPPORTED = {'zhimi.fan.za5', 'zhimi.airp.cpa4', 'xiaomi.derh.13l'}
BASE = Path(__file__).resolve().parent


def st_json(*args):
    proc = subprocess.run(['smartthings', *args, '--json'], capture_output=True, text=True, timeout=45)
    if proc.returncode:
        raise RuntimeError('SmartThings API request failed')
    return json.loads(proc.stdout)


def normalize(records):
    result = {}
    for d in records:
        if d.get('model') not in SUPPORTED:
            continue
        try:
            ip = ipaddress.IPv4Address(d.get('localip', ''))
            token = d.get('token', '')
            did = int(d['did'])
            if not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast:
                continue
            if len(token) != 32 or len(bytes.fromhex(token)) != 16 or token.lower() in ('0'*32, 'f'*32):
                continue
            if not 0 < did < 0xffffffff:
                continue
        except (ValueError, TypeError, KeyError):
            continue
        result[did] = {'did':did, 'ip':str(ip), 'token':token, 'model':d['model']}
    if len(result) > 20:
        raise RuntimeError('More than 20 supported devices; select a single region')
    return list(result.values())


def load_connector():
    # Upstream's CLI parses argv during import. Isolate it from our arguments;
    # main() is never called, so upstream never prints any device tokens.
    argv = sys.argv
    try:
        sys.argv = ['xiaomi-extractor', '--log_level', 'CRITICAL']
        spec = importlib.util.spec_from_file_location('xiaomi_extractor', BASE/'vendor/token_extractor.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    logging.disable(logging.CRITICAL)
    connector = module.QrCodeXiaomiCloudConnector()
    request = connector._session.request
    def bounded_request(method, url, **kwargs):
        kwargs.setdefault('timeout', 20)
        return request(method, url, **kwargs)
    connector._session.request = bounded_request
    return connector, module.SERVERS


def qr_login(connector, path):
    if not connector.login_step_1():
        raise RuntimeError('Xiaomi QR login initialization failed')
    response = connector._session.get(connector._qr_image_url)
    response.raise_for_status()
    from PIL import Image
    import io
    Image.open(io.BytesIO(response.content)).verify()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(response.content)
    print('QR_READY ' + str(path), flush=True)
    deadline = time.monotonic() + min(float(connector._timeout), 240)
    import requests
    try:
        while time.monotonic() < deadline:
            try:
                r = connector._session.get(connector._long_polling_url, timeout=10)
            except requests.exceptions.Timeout:
                continue
            if r.status_code != 200:
                time.sleep(1)
                continue
            data = connector.to_json(r.text)
            if not all(k in data for k in ['userId','ssecurity','location']):
                raise RuntimeError('QR confirmation did not return a valid session')
            connector.userId = data['userId']
            connector._ssecurity = data['ssecurity']
            connector._location = data['location']
            if not connector.login_step_4():
                raise RuntimeError('Xiaomi account confirmation failed')
            print('LOGIN_CONFIRMED', flush=True)
            return
        raise RuntimeError('QR expired; run the helper again')
    finally:
        path.unlink(missing_ok=True)


def cloud_devices(connector, regions):
    records = []
    for region in regions:
        response = connector.get_homes(region) or {}
        homes = [(h['id'], connector.userId) for h in response.get('result',{}).get('homelist',[])]
        response = connector.get_dev_cnt(region) or {}
        homes += [(h['home_id'], h['home_owner']) for h in response.get('result',{}).get('share',{}).get('share_family',[])]
        for home, owner in dict.fromkeys(homes):
            response = connector.get_devices(region, home, owner) or {}
            records.extend(response.get('result',{}).get('device_info') or [])
    return normalize(records)


def dispatch(transfer, setup, address, port):
    command = {'component':'main','capability':'earthpanel38939.xiaomiLocalLink',
               'command':'enroll','arguments':[address,port,transfer.key.hex()]}
    fd, path = tempfile.mkstemp(prefix='xiaomi-enroll-',suffix='.json')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(command, f)
        proc = subprocess.run(['smartthings','devices:commands',setup,'-i',path],capture_output=True,text=True,timeout=45)
        if proc.returncode:
            raise RuntimeError('SmartThings enrollment command failed')
    finally:
        os.unlink(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--region', choices=['all','cn','de','us','ru','tw','sg','in','i2'], default='all')
    parser.add_argument('--setup-device')
    args = parser.parse_args()
    devices = st_json('devices')
    setups = [d for d in devices if d.get('deviceModel') == 'xiaomi.setup'
              and d.get('lan',{}).get('driverId') == '730694c3-9d37-4f74-a1d3-8abed8021551'
              and (not args.setup_device or d['deviceId'] == args.setup_device)]
    if len(setups) != 1:
        raise RuntimeError('Add one Xiaomi setup device in SmartThings, or specify --setup-device')
    setup = setups[0]
    hub = st_json('devices', setup['lan']['hubId'])['hub']['hubData']['localIP']
    probe = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    try:
        probe.connect((hub, 54321))
        address = probe.getsockname()[0]
    finally:
        probe.close()
    connector, regions = load_connector()
    try:
        qr_login(connector, BASE/'.state/login.png')
        records = cloud_devices(connector, regions if args.region == 'all' else [args.region])
    finally:
        connector._session.close()
    if not records:
        raise RuntimeError('No supported LAN devices with usable tokens found; check Xiaomi Home region')
    print('SUPPORTED_DEVICES ' + str(len(records)), flush=True)
    for r in records:
        print('MODEL ' + r['model'], flush=True)
    transfer = Transfer(address, hub, setup['deviceId'], records)
    try:
        port = transfer.start()
        dispatch(transfer, setup['deviceId'], address, port)
        print('HUB_IMPORT_PENDING', flush=True)
        if not transfer.done.wait(max(0, transfer.deadline-time.monotonic())):
            raise RuntimeError('Hub did not confirm import before expiry')
        print('HUB_IMPORT_RESULT ' + json.dumps(transfer.result), flush=True)
        if transfer.result.get('failed'):
            raise RuntimeError('Some appliances failed local authentication; see setup status')
    finally:
        transfer.close()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('CANCELLED', flush=True)
        sys.exit(130)
    except Exception as error:
        # Third-party exceptions may contain account URLs or response bodies.
        if isinstance(error, RuntimeError):
            print('ERROR ' + str(error), flush=True)
        else:
            print('ERROR ' + type(error).__name__ + '; account details were not logged', flush=True)
        sys.exit(1)
