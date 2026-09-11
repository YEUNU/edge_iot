#!/usr/bin/env python3
"""Prepare persistent credentials/configuration and run the Docker Compose service."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess

from notifier import Auth, Client, DEFAULT_HOME, FAULTS, save_json


def prepare(home, args, parser):
    if not (home / "auth.json").exists():
        if args.auth_profile == "default":
            parser.error("Use a dedicated CLI profile; default login remains owned by CLI.")
        credentials = Path.home() / "Library/Application Support/@smartthings/cli/credentials.json"
        data = json.loads(credentials.read_text())
        key = args.auth_profile + ":api.smartthings.com"
        if key not in data:
            parser.error("First complete: smartthings locations -p " + args.auth_profile)
        auth = data[key]
        expiry = dt.datetime.fromisoformat(auth["expires"].replace("Z", "+00:00")).timestamp()
        save_json(home / "auth.json", {"accessToken": auth["accessToken"],
                  "refreshToken": auth["refreshToken"], "expiresAt": expiry})
        # Dedicated session ownership moves to the service. Never share a
        # rotating refresh token with an independently refreshing CLI profile.
        del data[key]
        save_json(credentials, data)
    client = Client(Auth(home / "auth.json"))
    devices = []
    for device_id in dict.fromkeys(args.device):
        device = client.api("/devices/" + device_id)
        model = device.get("deviceModel")
        if model not in FAULTS or device.get("locationId") != args.location:
            parser.error("Device model/location does not match supported notification configuration")
        devices.append({"id": device_id, "model": model, "label": device["label"]})
    if args.test_device:
        endpoint = client.api("/devices/" + args.test_device)
        if endpoint.get("deviceModel") != "xiaomi.alerts" or endpoint.get("locationId") != args.location:
            parser.error("Test device must be the Xiaomi alert endpoint in the same location")
    save_json(home / "config.json", {"locationId": args.location, "devices": devices,
                                    "pollSeconds": 15, "testDeviceId": args.test_device})
    source = Path(__file__).parent
    for name in ("notifier.py", "healthcheck.py", "Dockerfile", "compose.yaml", ".dockerignore"):
        if (source / name).resolve() != (home / name).resolve():
            shutil.copyfile(source / name, home / name)
        os.chmod(home / name, 0o600)
    # Single quotes suppress Compose variable interpolation within a path.
    if "'" in str(home) or "\n" in str(home):
        parser.error("Data directory cannot contain single quotes or newlines")
    (home / ".env").write_text(
        f"NOTIFIER_UID={os.getuid()}\nNOTIFIER_GID={os.getgid()}\nNOTIFIER_DATA_DIR='{home}'\n")
    os.chmod(home / ".env", 0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--location", required=True)
    parser.add_argument("--device", action="append", required=True)
    parser.add_argument("--test-device", help="Existing Xiaomi 알림 device ID for its test button")
    parser.add_argument("--auth-profile", default="xiaomi-alerts")
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_HOME)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    docker = shutil.which("docker")
    if not docker:
        parser.error("Docker with Compose is required")
    running = subprocess.run([docker, "inspect", "--format", "{{.State.Running}}", "xiaomi-notifications"],
                             capture_output=True, text=True)
    if running.returncode == 0 and running.stdout.strip() == "true":
        parser.error("Stop xiaomi-notifications before reconfiguring authentication/devices")
    home = args.data_dir.expanduser().resolve()
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (home / "service.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Stop the notification service before reconfiguring")
        prepare(home, args, parser)
    compose = [docker, "compose", "--project-directory", str(home)]
    subprocess.run(compose + ["config", "--quiet"], check=True)
    if not args.prepare_only:
        subprocess.run(compose + ["up", "-d", "--build"], check=True)
    print("Prepared" if args.prepare_only else "Started", "xiaomi-notifications in", home)


if __name__ == "__main__":
    main()
