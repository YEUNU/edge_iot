#!/usr/bin/env python3
"""SmartThings device notifications. Standard-library-only, single process owner."""
import argparse
import datetime as dt
import fcntl
import http.client
import json
import logging
import math
import os
from pathlib import Path
import signal
import ssl
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.smartthings.com/v1"
TOKEN_URL = "https://auth-global.api.smartthings.com/oauth/token"
CLI_CLIENT_ID = "d18cf96e-c626-4433-bf51-ddbb10c5d1ed"
DEFAULT_HOME = Path.home() / "Library/Application Support/Xiaomi Notifications"
FAULTS = {
    "xiaomi.derh.13l": {
        "noFault": None, "defrost": None,
        "waterFull": "물통이 가득 찼어요. 물통을 비우고 다시 장착해 주세요.",
        "sensorFault1": "센서 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
        "sensorFault2": "두 번째 센서 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
        "commFault1": "내부 통신 오류가 감지됐어요. 기기 상태를 확인해 주세요.",
        "filterClean": "필터 청소가 필요해요. 필터를 확인해 주세요.",
        "fanMotor": "팬 모터 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
        "overload": "과부하가 감지됐어요. 기기 상태를 확인해 주세요.",
        "lackOfRefrigerant": "냉매 부족이 감지됐어요. 기기 점검이 필요해요.",
    },
    "zhimi.airp.cpa4": {
        "noFault": None,
        "motorStuck": "모터 고장이 감지됐어요. 기기 상태를 확인해 주세요.",
        "sensorLost": "센서 연결 오류가 감지됐어요. 기기 상태를 확인해 주세요.",
    },
}


def save_json(path, data):
    """Replace atomically; never leave credentials/state with world-readable mode."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, ensure_ascii=False)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class RequestError(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__(f"HTTP {status}")


def object_value(value, error="invalid-response"):
    if not isinstance(value, dict):
        raise RequestError(error)
    return value


def object_field(value, key):
    return object_value(object_value(value).get(key, {}))


def valid_token(value):
    return isinstance(value, str) and bool(value) and all(33 <= ord(c) <= 126 for c in value)


def valid_cli_transfer(value):
    if (not isinstance(value, dict) or set(value) != {"profile", "refreshTokenHash"}
            or not isinstance(value.get("profile"), str)
            or not value["profile"] or value["profile"] == "default"
            or not isinstance(value.get("refreshTokenHash"), str)
            or len(value["refreshTokenHash"]) != 64
            or any(c not in "0123456789abcdef" for c in value["refreshTokenHash"])):
        return False
    try:
        value["profile"].encode()
    except UnicodeError:
        return False
    return True


def finite_number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def timestamp_value(value):
    if not isinstance(value, str) or "T" not in value:
        return None
    try:
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, OverflowError):
        return None
    return stamp if stamp.tzinfo is not None else None


def valid_timestamp(value):
    return timestamp_value(value) is not None


def occurrence_stamp(value):
    return timestamp_value(value.get("timestamp") if isinstance(value, dict) else value)


def same_occurrence(left, right):
    return (isinstance(left, dict) and isinstance(right, dict)
            and left.get("value") == right.get("value")
            and occurrence_stamp(left) is not None
            and occurrence_stamp(left) == occurrence_stamp(right))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward credentials to another destination.


HTTPS_CONTEXT = ssl.create_default_context()
HTTPS_CONTEXT.set_alpn_protocols(["http/1.1"])
if HTTPS_CONTEXT.post_handshake_auth is not None:
    HTTPS_CONTEXT.post_handshake_auth = True


def request_json(url, method="GET", data=None, token=None, form=False, accept="application/json"):
    try:
        headers = {"Accept": accept}
        body = None
        if data is not None:
            body = (urllib.parse.urlencode(data) if form else
                    json.dumps(data, ensure_ascii=False)).encode()
            headers["Content-Type"] = ("application/x-www-form-urlencoded" if form
                                       else "application/json")
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        # Reuse verified trust configuration; each request keeps its own
        # opener/handler and credentials, with redirects still disabled.
        https = urllib.request.HTTPSHandler(context=HTTPS_CONTEXT)
        with urllib.request.build_opener(NoRedirect, https).open(req, timeout=15) as response:
            return object_value(json.load(response))
    except urllib.error.HTTPError as exc:
        raise RequestError(exc.code) from None
    except (OSError, http.client.HTTPException, ValueError, RecursionError):
        raise RequestError("transport/invalid-response") from None


class Auth:
    def __init__(self, path, request=request_json, clock=time.time):
        self.path, self.request, self.clock = Path(path), request, clock
        self.data = object_value(json.loads(self.path.read_text()), "invalid-auth")
        if (not all(valid_token(self.data.get(k)) for k in ("accessToken", "refreshToken"))
                or not finite_number(self.data.get("expiresAt"))
                or ("refreshAt" in self.data and (not finite_number(self.data["refreshAt"])
                    or self.data["refreshAt"] > self.data["expiresAt"]))
                or ("cliTransfer" in self.data and not valid_cli_transfer(self.data["cliTransfer"]))):
            raise RequestError("invalid-auth")
        self.pending_data = None

    def refresh(self):
        if self.pending_data is None:
            result = object_value(self.request(TOKEN_URL, "POST", {
                "grant_type": "refresh_token", "client_id": CLI_CLIENT_ID,
                "refresh_token": self.data["refreshToken"],
            }, form=True), "invalid-token-response")
            lifetime = result.get("expires_in")
            if isinstance(lifetime, bool) or not isinstance(lifetime, (int, float, str)):
                raise RequestError("invalid-token-response")
            try:
                lifetime = float(lifetime)
            except (ValueError, OverflowError):
                raise RequestError("invalid-token-response") from None
            now = self.clock()
            if (not all(valid_token(result.get(k)) for k in ("access_token", "refresh_token"))
                    or not finite_number(lifetime) or lifetime <= 0
                    or not finite_number(now + lifetime)):
                raise RequestError("invalid-token-response")
            self.pending_data = {"accessToken": result["access_token"],
                                 "refreshToken": result["refresh_token"],
                                 "expiresAt": now + lifetime,
                                 "refreshAt": now + lifetime - min(3600, lifetime / 10)}
            if "cliTransfer" in self.data:
                self.pending_data["cliTransfer"] = dict(self.data["cliTransfer"])
        # A temporary write failure must not discard an already rotated token.
        # Retry persistence before using it or requesting another rotation.
        save_json(self.path, self.pending_data)
        self.data = self.pending_data
        self.pending_data = None
        logging.info("OAuth refreshed and saved")

    def token(self):
        if self.pending_data is not None or self.clock() >= self.data.get("refreshAt", self.data["expiresAt"] - 3600):
            self.refresh()
        return self.data["accessToken"]


class Client:
    def __init__(self, auth, request=request_json):
        self.auth, self.request = auth, request

    def api(self, path, method="GET", data=None):
        options = {}
        base = API
        # Match the official SDK's device metadata/preferences API version;
        # the generic JSON representation omits deviceModel.
        if path.startswith("/devices/") and (path.count("/") == 2 or path.endswith("/preferences")):
            options["accept"] = "application/vnd.smartthings+json;v=20170916"
            base = "https://api.smartthings.com"
        # An OAuth endpoint rejection is an authentication failure, not a
        # device API 401. Only the latter permits one refresh and API retry.
        token = self.auth.token()
        try:
            return object_value(self.request(base + path, method, data, token=token, **options))
        except RequestError as exc:
            if exc.status != 401:
                raise
        self.auth.refresh()
        return object_value(self.request(base + path, method, data, token=self.auth.token(), **options))

    def notify(self, location, device, message):
        text = {"title": device["label"], "body": message}
        response = self.api("/notification", "POST", {
            "locationId": location, "type": "AUTOMATION_INFO",
            "messages": [{"default": text, "ko_KR": text}],
            "deepLink": {"type": "device", "id": device["id"]},
        })
        if response.get("code") != 2000000 or response.get("message") != "SUCCESS":
            raise RequestError("notification-rejected")


def conditions(device, status):
    main = object_field(object_field(status, "components"), "main")
    definitions = [("fault", "earthpanel38939.deviceFault", "fault", FAULTS[device["model"]])]
    if device["model"] == "zhimi.airp.cpa4":
        definitions.append(("filter", "earthpanel38939.filterAlert", "status", {
            "normal": None, "replace": "필터 수명이 10% 이하예요. 교체할 필터를 준비해 주세요.",
        }))
    for key, cap, attr, messages in definitions:
        try:
            reading = object_field(object_field(main, cap), attr)
        except RequestError:
            # Fault and filter warnings are independent. One malformed reading
            # cannot discard a valid warning from the other capability.
            continue
        value, stamp = reading.get("value"), reading.get("timestamp")
        # Missing/unknown reads never clear a warning. Timestamp distinguishes
        # recurrence even if normal -> warning happened between our polls.
        if isinstance(value, str) and value in messages and valid_timestamp(stamp):
            yield key, {"value": value, "timestamp": stamp}, messages[value]


class Monitor:
    def __init__(self, config, state_path, client, clock=time.time):
        self.config, self.path, self.client, self.clock = config, Path(state_path), client, clock
        try:
            self.state = object_value(json.loads(self.path.read_text()), "invalid-state") if self.path.exists() else {}
            # Reject corrupt but parseable JSON before accepting any pushes;
            # it must remain possible to persist the complete dedup state.
            json.dumps(self.state, ensure_ascii=False, allow_nan=False).encode()
        except (ValueError, RecursionError):
            raise RequestError("invalid-state") from None
        self.retry = {}
        self.started_at = self.clock()
        self.cloud_reads = {device["id"]: None for device in config["devices"]}
        if config.get("testDeviceId"):
            self.cloud_reads[config["testDeviceId"]] = None
        self.state_dirty = False

    def save_state(self):
        self.state_dirty = True
        self.flush_state()

    def flush_state(self):
        if not self.state_dirty:
            return
        try:
            save_json(self.path, self.state)
        except OSError as exc:
            logging.warning("notification state save unavailable (%s)", exc)
        else:
            self.state_dirty = False

    def health(self, checked):
        return {"lastPollAt": self.clock(), "startedAt": self.started_at,
                "lastCloudReadAt": max((stamp for stamp in self.cloud_reads.values() if stamp is not None), default=0),
                "deviceCloudReads": dict(self.cloud_reads), "checkedDevices": checked,
                "pendingRetries": len(self.retry), "stateSaved": not self.state_dirty}

    def defer_push(self, state_key, occurrence, pending, label, key, error):
        delay = min(pending[2] * 2 if pending else 30, 900)
        self.retry[state_key] = (occurrence, self.clock() + delay, delay)
        logging.warning("push retry %s %s in %ss (%s)", label, key, delay, error)

    def current_occurrence(self, key, occurrence):
        stamp = occurrence_stamp(occurrence)
        saved = occurrence_stamp(self.state.get(key))
        pending = self.retry.get(key)
        pending_stamp = occurrence_stamp(pending[0]) if pending else None
        return all(previous is None or stamp >= previous for previous in (saved, pending_stamp))

    def poll_test(self):
        device_id = self.config.get("testDeviceId")
        if not device_id:
            return
        try:
            status = self.client.api("/devices/" + device_id + "/status")
            reading = object_field(object_field(object_field(object_field(status, "components"), "main"),
                                                "earthpanel38939.latestAlert"), "message")
            stamp = reading.get("timestamp")
            if not valid_timestamp(stamp) or not isinstance(reading.get("value"), str):
                return
            key = "test:" + device_id
            if not self.current_occurrence(key, stamp):
                return
            self.cloud_reads[device_id] = self.clock()
            if key not in self.state:
                self.state[key] = stamp  # Do not replay historical button requests on installation.
                self.save_state()
                return
            pending = self.retry.get(key)
            if pending and occurrence_stamp(pending[0]) != occurrence_stamp(stamp):
                self.retry.pop(key)
                pending = None
            if occurrence_stamp(self.state[key]) == occurrence_stamp(stamp):
                return
            if reading.get("value") == "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.":
                if pending and self.clock() < pending[1]:
                    return
                try:
                    self.client.notify(self.config["locationId"], {"id": device_id, "label": "Xiaomi 알림"},
                                       "Mac 알림 서비스가 정상 동작합니다. 루틴 없이 보낸 테스트입니다.")
                except (RequestError, OSError) as exc:
                    self.defer_push(key, stamp, pending, "Xiaomi 알림", "test", exc)
                    return
                logging.info("app test push accepted")
            self.state[key] = stamp
            self.retry.pop(key, None)
            self.save_state()
        except (RequestError, OSError) as exc:
            logging.warning("test request unavailable (%s)", exc)

    def poll(self):
        self.poll_test()
        checked = 0
        for device in self.config["devices"]:
            try:
                health = object_value(self.client.api("/devices/" + device["id"] + "/health"))
                if health.get("state") not in ("ONLINE", "OFFLINE"):
                    raise RequestError("invalid-device-health")
                if health["state"] == "OFFLINE":
                    checked += 1
                    self.cloud_reads[device["id"]] = self.clock()
                    continue
                status = self.client.api("/devices/" + device["id"] + "/status")
                readings = [(key, occurrence, message) for key, occurrence, message in conditions(device, status)
                            if self.current_occurrence(device["id"] + ":" + key, occurrence)]
                expected = 2 if device["model"] == "zhimi.airp.cpa4" else 1
                if len(readings) == expected:
                    checked += 1
                    self.cloud_reads[device["id"]] = self.clock()
                else:
                    logging.warning("status incomplete %s", device["label"])
                for key, occurrence, message in readings:
                    state_key = device["id"] + ":" + key
                    pending = self.retry.get(state_key)
                    if pending and not same_occurrence(pending[0], occurrence):
                        self.retry.pop(state_key)
                        pending = None
                    if same_occurrence(self.state.get(state_key), occurrence):
                        continue
                    if message:
                        if pending and self.clock() < pending[1]:
                            continue
                        try:
                            self.client.notify(self.config["locationId"], device, message)
                        except (RequestError, OSError) as exc:
                            self.defer_push(state_key, occurrence, pending, device["label"], key, exc)
                            continue
                        logging.info("push accepted %s %s=%s", device["label"], key, occurrence["value"])
                    self.state[state_key] = occurrence
                    self.retry.pop(state_key, None)
                    self.save_state()
            except (RequestError, OSError) as exc:
                logging.warning("status unavailable %s (%s)", device["label"], exc)
        self.flush_state()
        return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=DEFAULT_HOME)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--refresh-auth", action="store_true")
    parser.add_argument("--test", metavar="DEVICE_ID")
    args = parser.parse_args()
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args.home.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.home / "service.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("notification service already running")
        config = json.loads((args.home / "config.json").read_text())
        auth = Auth(args.home / "auth.json")
        client = Client(auth)
        if args.refresh_auth:
            auth.refresh()
            return
        if args.test:
            device = next(d for d in config["devices"] if d["id"] == args.test)
            client.notify(config["locationId"], device,
                          "기기별 직접 알림 테스트입니다. 루틴 없이 보냈으며 실제 고장이 아닙니다.")
            logging.info("test push accepted %s", device["label"])
            return
        monitor = Monitor(config, args.home / "state.json", client)
        running = True
        def stop(*_):
            nonlocal running
            running = False
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        logging.info("notification service started (%s devices)", len(config["devices"]))
        while running:
            checked = monitor.poll()
            try:
                save_json(args.home / "health.json", monitor.health(checked))
            except OSError as exc:
                logging.warning("health state save unavailable (%s)", exc)
            if args.once:
                return
            for _ in range(config.get("pollSeconds", 15)):
                if not running:
                    break
                time.sleep(1)


if __name__ == "__main__":
    main()
