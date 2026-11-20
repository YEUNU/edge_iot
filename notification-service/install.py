#!/usr/bin/env python3
"""Prepare persistent credentials/configuration and run the Docker Compose service."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess

from notifier import Auth, Client, CONDITIONS, DEFAULT_HOME, NAMESPACE, finite_number, save_json, timestamp_value, valid_token


def prepare(home, args, parser):
    credentials = Path.home() / "Library/Application Support/@smartthings/cli/credentials.json"
    if not (home / "auth.json").exists():
        if not args.auth_profile or args.auth_profile == "default":
            parser.error("Use a dedicated CLI profile; default login remains owned by CLI.")
        data = json.loads(credentials.read_text())
        if not isinstance(data, dict):
            parser.error("CLI credentials must be an object")
        key = args.auth_profile + ":api.smartthings.com"
        if key not in data:
            parser.error("First complete: smartthings locations -p " + args.auth_profile)
        auth = data[key]
        if not isinstance(auth, dict) or not all(valid_token(auth.get(k)) for k in ("accessToken", "refreshToken")):
            parser.error("CLI profile credentials are invalid")
        expires = timestamp_value(auth.get("expires"))
        if expires is None:
            parser.error("CLI profile expiry must include a valid timezone")
        try:
            expiry = expires.timestamp()
        except (ValueError, OverflowError, OSError):
            parser.error("CLI profile expiry is invalid")
        if not finite_number(expiry):
            parser.error("CLI profile expiry is invalid")
        save_json(home / "auth.json", {"accessToken": auth["accessToken"],
                  "refreshToken": auth["refreshToken"], "expiresAt": expiry})
        del data[key]
        save_json(credentials, data)
    auth = Auth(home / "auth.json")
    client = Client(auth)
    devices = []
    for device_id in dict.fromkeys(args.device):
        device = client.api("/devices/" + device_id)
        model = device.get("deviceModel")
        if not isinstance(model, str) or model not in CONDITIONS or device.get("locationId") != args.location:
            parser.error("Device model/location does not match supported notification configuration")
        label = device.get("label")
        if not isinstance(label, str) or not label:
            parser.error("Device label is missing or invalid")
        try:
            label.encode()
        except UnicodeError:
            parser.error("Device label is invalid Unicode")
        devices.append({"id": device_id, "model": model, "label": label})
    if args.test_device:
        endpoint = client.api("/devices/" + args.test_device)
        if endpoint.get("deviceModel") != "xiaomi.alerts" or endpoint.get("locationId") != args.location:
            parser.error("Test device must be the Xiaomi alert endpoint in the same location")
    save_json(home / "config.json", {"locationId": args.location, "devices": devices,
                                    "pollSeconds": 15, "testDeviceId": args.test_device})
    source = Path(__file__).resolve().parent
    data_dir = str(home).translate(str.maketrans({
        "\\": "\\\\", '"': '\\"', "$": "$$", "\n": "\\n", "\r": "\\r", "\t": "\\t",
    }))
    env_text = (
        f'NOTIFIER_UID={os.getuid()}\n'
        f'NOTIFIER_GID={os.getgid()}\n'
        f'NOTIFIER_DATA_DIR="{data_dir}"\n'
        f'SMARTTHINGS_NAMESPACE="{NAMESPACE}"\n'
    )
    for env_dir in {source, home}:
        (env_dir / ".env").write_text(env_text)
        os.chmod(env_dir / ".env", 0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--location", required=True)
    parser.add_argument("--device", action="append", required=True)
    parser.add_argument("--test-device", help="Existing Xiaomi 알림 device ID for its test button")
    parser.add_argument("--auth-profile", default="xiaomi-alerts")
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_HOME)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    home = args.data_dir.expanduser().resolve()
    source = Path(__file__).resolve().parent
    os.umask(0o077)
    docker = shutil.which("docker")
    if not docker:
        parser.error("Docker with Compose is required")
    running = subprocess.run([docker, "inspect", "--format", "{{.State.Running}}", "xiaomi-notifications"],
                             capture_output=True, text=True)
    if running.returncode == 0 and running.stdout.strip() == "true":
        parser.error("Stop xiaomi-notifications before reconfiguring authentication/devices")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (home / "service.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Stop the notification service before reconfiguring")
        prepare(home, args, parser)
    compose = [docker, "compose", "--project-directory", str(source), "--env-file", str(home / ".env")]
    subprocess.run(compose + ["config", "--quiet"], check=True)
    if not args.prepare_only:
        subprocess.run(compose + ["up", "-d", "--build"], check=True)
    print("Prepared" if args.prepare_only else "Started", "xiaomi-notifications in", home)


if __name__ == "__main__":
    main()
