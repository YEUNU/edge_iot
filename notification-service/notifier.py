#!/usr/bin/env python3
"""SmartThings device notifications. Standard-library-only, single process owner."""
import argparse
import fcntl
import json
import logging
import os
from pathlib import Path
import signal
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward credentials to another destination.


def request_json(url, method="GET", data=None, token=None, form=False, accept="application/json"):
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
    try:
        # Python's default SSL context verifies both CA chain and hostname.
        with urllib.request.build_opener(NoRedirect).open(req, timeout=15) as response:
            result = json.load(response)
            if not isinstance(result, dict):
                raise ValueError("expected object")
            return result
    except urllib.error.HTTPError as exc:
        raise RequestError(exc.code) from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise RequestError("transport/invalid-response") from None


class Auth:
    def __init__(self, path, request=request_json, clock=time.time):
        self.path, self.request, self.clock = Path(path), request, clock
        self.data = json.loads(self.path.read_text())

    def refresh(self):
        result = self.request(TOKEN_URL, "POST", {
            "grant_type": "refresh_token", "client_id": CLI_CLIENT_ID,
            "refresh_token": self.data["refreshToken"],
        }, form=True)
        if not all(result.get(k) for k in ("access_token", "refresh_token", "expires_in")):
            raise RequestError("invalid-token-response")
        updated = {"accessToken": result["access_token"],
                   "refreshToken": result["refresh_token"],
                   "expiresAt": self.clock() + float(result["expires_in"])}
        save_json(self.path, updated)  # Save rotated refresh token before any API call.
        self.data = updated
        logging.info("OAuth refreshed and saved")

    def token(self):
        if self.clock() >= self.data["expiresAt"] - 3600:
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
        try:
            return self.request(base + path, method, data, token=self.auth.token(), **options)
        except RequestError as exc:
            if exc.status != 401:
                raise
        self.auth.refresh()
        return self.request(base + path, method, data, token=self.auth.token(), **options)

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
    main = status.get("components", {}).get("main", {})
    definitions = [("fault", "earthpanel38939.deviceFault", "fault", FAULTS[device["model"]])]
    if device["model"] == "zhimi.airp.cpa4":
        definitions.append(("filter", "earthpanel38939.filterAlert", "status", {
            "normal": None, "replace": "필터 수명이 10% 이하예요. 교체할 필터를 준비해 주세요.",
        }))
    for key, cap, attr, messages in definitions:
        reading = main.get(cap, {}).get(attr, {})
        value, stamp = reading.get("value"), reading.get("timestamp")
        # Missing/unknown reads never clear a warning. Timestamp distinguishes
        # recurrence even if normal -> warning happened between our polls.
        if isinstance(value, str) and value in messages and isinstance(stamp, str):
            yield key, {"value": value, "timestamp": stamp}, messages[value]


class Monitor:
    def __init__(self, config, state_path, client, clock=time.time):
        self.config, self.path, self.client, self.clock = config, Path(state_path), client, clock
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.retry = {}

    def poll_test(self):
        device_id = self.config.get("testDeviceId")
        if not device_id:
            return
        try:
            status = self.client.api("/devices/" + device_id + "/status")
            reading = status.get("components", {}).get("main", {}).get(
                "earthpanel38939.latestAlert", {}).get("message", {})
            stamp = reading.get("timestamp")
            if not isinstance(stamp, str):
                return
            key = "test:" + device_id
            if key not in self.state:
                self.state[key] = stamp  # Do not replay historical button requests on installation.
                save_json(self.path, self.state)
                return
            if self.state[key] == stamp:
                return
            if reading.get("value") == "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.":
                self.client.notify(self.config["locationId"], {"id": device_id, "label": "Xiaomi 알림"},
                                   "Mac 알림 서비스가 정상 동작합니다. 루틴 없이 보낸 테스트입니다.")
                logging.info("app test push accepted")
            self.state[key] = stamp
            save_json(self.path, self.state)
        except RequestError as exc:
            logging.warning("test request unavailable (%s)", exc)

    def poll(self):
        self.poll_test()
        checked = 0
        for device in self.config["devices"]:
            try:
                health = self.client.api("/devices/" + device["id"] + "/health")
                if health.get("state") != "ONLINE":
                    checked += 1
                    continue
                status = self.client.api("/devices/" + device["id"] + "/status")
                checked += 1
                for key, occurrence, message in conditions(device, status):
                    state_key = device["id"] + ":" + key
                    if self.state.get(state_key) == occurrence:
                        continue
                    pending = self.retry.get(state_key)
                    if pending and pending[0] != occurrence:
                        self.retry.pop(state_key)
                        pending = None
                    if message:
                        if pending and self.clock() < pending[1]:
                            continue
                        try:
                            self.client.notify(self.config["locationId"], device, message)
                        except RequestError as exc:
                            delay = min(pending[2] * 2 if pending else 30, 900)
                            self.retry[state_key] = (occurrence, self.clock() + delay, delay)
                            logging.warning("push retry %s %s in %ss (%s)", device["label"], key, delay, exc)
                            continue
                        logging.info("push accepted %s %s=%s", device["label"], key, occurrence["value"])
                    self.state[state_key] = occurrence
                    self.retry.pop(state_key, None)
                    save_json(self.path, self.state)
            except RequestError as exc:
                logging.warning("status unavailable %s (%s)", device["label"], exc)
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
        last_cloud_read = 0
        while running:
            checked = monitor.poll()
            if checked:
                last_cloud_read = time.time()
            save_json(args.home / "health.json", {"lastPollAt": time.time(),
                      "lastCloudReadAt": last_cloud_read, "checkedDevices": checked,
                      "pendingRetries": len(monitor.retry)})
            if args.once:
                return
            for _ in range(config.get("pollSeconds", 15)):
                if not running:
                    break
                time.sleep(1)


if __name__ == "__main__":
    main()
