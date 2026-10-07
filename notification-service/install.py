#!/usr/bin/env python3
"""Prepare persistent credentials/configuration and run the Docker Compose service."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from notifier import Auth, Client, DEFAULT_HOME, FAULTS, finite_number, save_json, timestamp_value, valid_token


def token_fingerprint(token):
    if not isinstance(token, str):
        return None
    try:
        return hashlib.sha256(token.encode()).hexdigest()
    except UnicodeError:
        return None


def validate_data_dir(home, parser):
    if "'" in str(home) or "\n" in str(home) or "\r" in str(home):
        parser.error("Data directory cannot contain single quotes or newlines")


def prepare(home, args, parser):
    validate_data_dir(home, parser)
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
                  "refreshToken": auth["refreshToken"], "expiresAt": expiry,
                  "cliTransfer": {"profile": args.auth_profile,
                                  "refreshTokenHash": token_fingerprint(auth["refreshToken"])}})
    auth = Auth(home / "auth.json")
    transfer = auth.data.get("cliTransfer")
    if transfer is not None:
        profile, fingerprint = transfer["profile"], transfer["refreshTokenHash"]
    else:
        # Recover an interrupted installation written by an older version only
        # when the selected dedicated profile still holds this exact token.
        profile = args.auth_profile
        fingerprint = token_fingerprint(auth.data["refreshToken"]) if profile != "default" else None
    if fingerprint is not None and credentials.exists():
        try:
            data = json.loads(credentials.read_text())
            if not isinstance(data, dict):
                raise ValueError("CLI credentials must be an object")
        except (OSError, ValueError, RecursionError):
            if transfer is not None:
                parser.error("Cannot finish authentication transfer: CLI credentials are unreadable")
            # An already installed service remains independent of unrelated
            # CLI file damage; only journaled ownership must finish first.
        else:
            key = profile + ":api.smartthings.com"
            candidate = data.get(key)
            if isinstance(candidate, dict) and token_fingerprint(candidate.get("refreshToken")) == fingerprint:
                # Persist the service copy before removing only the imported CLI
                # session. A failed removal is resumed even after service rotation;
                # a newer, independent CLI login in that profile remains untouched.
                del data[key]
                save_json(credentials, data)
    if transfer is not None:
        completed = dict(auth.data)
        completed.pop("cliTransfer")
        save_json(home / "auth.json", completed)
        auth.data = completed
    client = Client(auth)
    devices = []
    for device_id in dict.fromkeys(args.device):
        device = client.api("/devices/" + device_id)
        model = device.get("deviceModel")
        if not isinstance(model, str) or model not in FAULTS or device.get("locationId") != args.location:
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
    source = Path(__file__).parent
    for name in ("notifier.py", "healthcheck.py", "Dockerfile", "compose.yaml", ".dockerignore"):
        if (source / name).resolve() != (home / name).resolve():
            shutil.copyfile(source / name, home / name)
        os.chmod(home / name, 0o600)
    # Single quotes suppress Compose variable interpolation within a path.
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
    home = args.data_dir.expanduser().resolve()
    validate_data_dir(home, parser)
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
    compose = [docker, "compose", "--project-directory", str(home)]
    subprocess.run(compose + ["config", "--quiet"], check=True)
    if not args.prepare_only:
        subprocess.run(compose + ["up", "-d", "--build"], check=True)
    print("Prepared" if args.prepare_only else "Started", "xiaomi-notifications in", home)


if __name__ == "__main__":
    main()
