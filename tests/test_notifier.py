import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("notifier", Path(__file__).resolve().parents[1] / "notification-service/notifier.py")
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)

DEVICE = {"id": "dehumidifier", "label": "제습기", "model": "xiaomi.derh.13l"}
CONFIG = {"locationId": "home", "devices": [DEVICE]}


def status(value="waterFull", stamp="2026-09-11T11:00:00Z"):
    return {"components": {"main": {"earthpanel38939.deviceFault": {
        "fault": {"value": value, "timestamp": stamp}}}}}


class FakeClient:
    def __init__(self):
        self.status = status()
        self.online = True
        self.fail = False
        self.sent = []
        self.attempts = 0

    def api(self, path):
        if path.endswith("/health"):
            return {"state": "ONLINE" if self.online else "OFFLINE"}
        return self.status

    def notify(self, location, device, message):
        self.attempts += 1
        if self.fail:
            raise n.RequestError(503)
        self.sent.append((location, device["id"], message))


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.json"
        self.client = FakeClient()
        self.now = 1000
        self.monitor = n.Monitor(CONFIG, self.path, self.client, lambda: self.now)

    def test_dedup_survives_restart(self):
        for _ in range(100):
            self.monitor.poll()
        n.Monitor(CONFIG, self.path, self.client).poll()
        self.assertEqual(len(self.client.sent), 1)

    def test_recovery_rearms(self):
        for value in ["waterFull", "noFault", "waterFull", "defrost", "waterFull"]:
            self.client.status = status(value)
            self.monitor.poll()
        self.assertEqual(len(self.client.sent), 3)

    def test_timestamp_catches_recurrence_between_polls(self):
        self.monitor.poll()
        self.client.status = status(stamp="2026-09-11T11:01:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)

    def test_failure_backoff_and_success(self):
        self.client.fail = True
        self.monitor.poll()
        for _ in range(20):
            self.monitor.poll()
        self.assertEqual(self.client.attempts, 1)
        self.assertFalse(self.path.exists())
        self.now += 30
        self.client.fail = False
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.assertTrue(self.path.exists())

    def test_recovery_cancels_failed_warning(self):
        self.client.fail = True
        self.monitor.poll()
        self.client.status = status("noFault")
        self.monitor.poll()
        self.now += 1000
        self.client.fail = False
        self.monitor.poll()
        self.assertEqual(self.client.sent, [])
        self.assertEqual(self.monitor.retry, {})

    def test_different_warning_bypasses_previous_backoff(self):
        self.client.fail = True
        self.monitor.poll()
        self.client.status = status("overload")
        self.client.fail = False
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.assertIn("과부하", self.client.sent[0][2])

    def test_invalid_and_offline_do_not_clear(self):
        self.monitor.poll()
        saved = self.path.read_text()
        for invalid in [{}, status("unknown"), status(None), status([], None)]:
            self.client.status = invalid
            self.monitor.poll()
        self.client.status = status("noFault")
        self.client.online = False
        self.monitor.poll()
        self.assertEqual(self.path.read_text(), saved)

    def test_purifier_fault_and_filter_are_independent(self):
        device = dict(DEVICE, id="purifier", model="zhimi.airp.cpa4")
        self.monitor.config = {"locationId": "home", "devices": [device]}
        self.client.status = status("motorStuck")
        self.client.status["components"]["main"]["earthpanel38939.filterAlert"] = {
            "status": {"value": "replace", "timestamp": "2026-09-11T11:00:00Z"}}
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)

    def test_app_test_button_ignores_history_then_sends_once(self):
        self.client.status = status("noFault")
        self.monitor.config = dict(CONFIG, testDeviceId="endpoint")
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": {
            "value": "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.",
            "timestamp": "2026-09-11T11:00:00Z"}}}}}
        original = self.client.api
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        self.monitor.poll()
        self.assertEqual(self.client.sent, [])
        request["components"]["main"]["earthpanel38939.latestAlert"]["message"]["timestamp"] = "2026-09-11T11:01:00Z"
        self.monitor.poll()
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.assertEqual(self.client.sent[0][1], "endpoint")


class AuthTests(unittest.TestCase):
    def test_rotated_token_persisted_and_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            n.save_json(path, {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1})
            requests = []
            def request(url, method, data, **kwargs):
                requests.append(data)
                return {"access_token": "new", "refresh_token": "r2", "expires_in": 86400}
            auth = n.Auth(path, request, lambda: 1000)
            self.assertEqual(auth.token(), "new")
            self.assertEqual(n.Auth(path, request, lambda: 1001).token(), "new")
            self.assertEqual(json.loads(path.read_text())["refreshToken"], "r2")
            self.assertEqual(len(requests), 1)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_failed_refresh_preserves_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            n.save_json(path, {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1})
            original = path.read_text()
            auth = n.Auth(path, lambda *a, **k: {}, lambda: 1000)
            with self.assertRaises(n.RequestError):
                auth.token()
            self.assertEqual(path.read_text(), original)

    def test_unauthorized_refreshes_once(self):
        class Auth:
            count = 0
            def token(self): return "old" if not self.count else "new"
            def refresh(self): self.count += 1
        auth = Auth()
        def request(*args, **kwargs):
            if kwargs["token"] == "old": raise n.RequestError(401)
            return {"ok": True}
        self.assertTrue(n.Client(auth, request).api("/devices")["ok"])
        self.assertEqual(auth.count, 1)

    def test_payload_links_to_physical_device_and_requires_semantic_success(self):
        class Auth:
            def token(self): return "example"
        payloads = []
        def request(url, method, data, **kwargs):
            payloads.append(data)
            return {"code": 2000000, "message": "SUCCESS"}
        client = n.Client(Auth(), request)
        client.notify("home", DEVICE, "물통을 비워 주세요.")
        payload = payloads[0]
        self.assertEqual(payload["deepLink"], {"type": "device", "id": "dehumidifier"})
        self.assertEqual(payload["messages"][0]["ko_KR"]["title"], "제습기")
        client.request = lambda *a, **k: {"code": 4000000}
        with self.assertRaises(n.RequestError):
            client.notify("home", DEVICE, "test")


if __name__ == "__main__":
    unittest.main()
