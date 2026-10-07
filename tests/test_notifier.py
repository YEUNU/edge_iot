import importlib.util
import http.client
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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

    def test_corrupt_state_is_preserved_and_rejected_before_any_push(self):
        invalids = ["null", "[]", "{", '{"old":{"timestamp":"\\ud800"}}',
                    '{"old":NaN}', '{"old":Infinity}',
                    '{"old":' + '[' * 1200 + '0' + ']' * 1200 + '}']
        for text in invalids:
            with self.subTest(state=text[:60]):
                self.path.write_text(text)
                with self.assertRaises(n.RequestError):
                    n.Monitor(CONFIG, self.path, self.client, lambda: self.now)
                self.assertEqual(self.path.read_text(), text)
                self.assertEqual(self.client.attempts, 0)

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

    def test_older_recovery_cannot_rearm_an_already_sent_warning(self):
        warning = status(stamp="2026-09-11T11:01:00Z")
        self.client.status = warning
        self.monitor.poll()
        saved = dict(self.monitor.state)
        self.now += 30
        self.client.status = status("noFault", "2026-09-11T11:00:00Z")
        self.assertEqual(self.monitor.poll(), 0)
        self.assertEqual(self.monitor.state, saved)
        self.assertEqual(self.monitor.cloud_reads[DEVICE["id"]], 1000)
        self.client.status = warning
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.client.status = status("noFault", "2026-09-11T11:02:00Z")
        self.monitor.poll()
        self.client.status = status(stamp="2026-09-11T11:03:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)

    def test_older_recovery_preserves_pending_warning_and_timezone_equivalence_keeps_backoff(self):
        self.client.status = status("noFault", "2026-09-11T11:00:00Z")
        self.monitor.poll()
        self.client.status = status(stamp="2026-09-11T11:01:00Z")
        self.client.fail = True
        self.monitor.poll()
        pending = self.monitor.retry["dehumidifier:fault"]
        self.client.status = status("noFault", "2026-09-11T11:00:00Z")
        self.monitor.poll()
        self.assertEqual(self.monitor.retry["dehumidifier:fault"], pending)
        self.client.status = status(stamp="2026-09-11T20:01:00+09:00")
        self.monitor.poll()
        self.assertEqual(self.client.attempts, 1)
        self.assertEqual(self.monitor.retry["dehumidifier:fault"], pending)
        self.now += 30
        self.client.fail = False
        self.monitor.poll()
        self.client.status = status(stamp="2026-09-11T11:01:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)

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

    def test_malformed_filter_does_not_discard_valid_fault_warning(self):
        device = dict(DEVICE, id="purifier", model="zhimi.airp.cpa4")
        for malformed in [None, [], 1, "bad", {"status": None}, {"status": []}]:
            with self.subTest(filter=malformed), tempfile.TemporaryDirectory() as tmp:
                client = FakeClient()
                client.status = status("motorStuck")
                client.status["components"]["main"]["earthpanel38939.filterAlert"] = malformed
                monitor = n.Monitor({"locationId": "home", "devices": [device]},
                                    Path(tmp) / "state.json", client, lambda: self.now)
                self.assertEqual(monitor.poll(), 0)
                self.assertEqual(len(client.sent), 1)
                self.assertEqual(monitor.state["purifier:fault"]["value"], "motorStuck")
                self.assertIsNone(monitor.cloud_reads["purifier"])
                monitor.poll()
                self.assertEqual(len(client.sent), 1)

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

    def test_invalid_nested_status_isolated_from_other_devices(self):
        second = dict(DEVICE, id="second")
        self.monitor.config = dict(CONFIG, devices=[DEVICE, second])
        self.monitor.cloud_reads[second["id"]] = None
        original = self.client.api
        invalids = [None, [], {"components": None}, {"components": []},
                    {"components": {"main": None}}, {"components": {"main": []}},
                    {"components": {"main": {"earthpanel38939.deviceFault": None}}},
                    {"components": {"main": {"earthpanel38939.deviceFault": {"fault": []}}}}]
        for invalid in invalids:
            with self.subTest(invalid=invalid):
                self.client.api = lambda path: invalid if "/dehumidifier/status" in path else original(path)
                self.assertEqual(self.monitor.poll(), 1)
                self.assertIsNone(self.monitor.cloud_reads[DEVICE["id"]])
                self.assertEqual(self.monitor.cloud_reads[second["id"]], self.now)
        self.assertEqual(len(self.client.sent), 1)
        self.assertEqual(self.client.sent[0][1], "second")

    def test_invalid_health_does_not_count_as_offline(self):
        for invalid in [None, [], {}, {"state": None}, {"state": "unknown"}, {"state": []}]:
            with self.subTest(invalid=invalid):
                self.client.api = lambda path: invalid
                self.assertEqual(self.monitor.poll(), 0)
                self.assertIsNone(self.monitor.cloud_reads[DEVICE["id"]])
        self.assertEqual(self.client.sent, [])

    def test_unknown_missing_and_empty_timestamp_do_not_mark_success(self):
        for invalid in [{}, status("unknown"), status(stamp=""), status(stamp=None)]:
            with self.subTest(invalid=invalid):
                self.client.status = invalid
                self.assertEqual(self.monitor.poll(), 0)
                self.assertIsNone(self.monitor.cloud_reads[DEVICE["id"]])
        self.assertEqual(self.client.sent, [])

    def test_malformed_timestamp_does_not_send_clear_or_block_other_devices(self):
        devices = [DEVICE, dict(DEVICE, id="second")]
        invalids = ["invalid", "2026-09-11", "2026-09-11T11:00:00", "2026-02-30T11:00:00Z", "\ud800"]
        for invalid in invalids:
            with self.subTest(timestamp=ascii(invalid)), tempfile.TemporaryDirectory() as tmp:
                client = FakeClient()
                original = client.api
                client.api = lambda path: status(stamp=invalid) if "/dehumidifier/status" in path else original(path)
                monitor = n.Monitor(dict(CONFIG, devices=devices), Path(tmp) / "state.json", client, lambda: self.now)
                self.assertEqual(monitor.poll(), 1)
                self.assertEqual([sent[1] for sent in client.sent], ["second"])
                self.assertNotIn("dehumidifier:fault", monitor.state)
                self.assertIsNone(monitor.cloud_reads[DEVICE["id"]])
                self.assertTrue(monitor.path.exists())

    def test_supported_iso_timestamps_are_accepted(self):
        for stamp in ["2026-09-11T11:00:00Z", "2026-09-11T11:00:00.123Z", "2026-09-11T20:00:00+09:00"]:
            with self.subTest(timestamp=stamp):
                self.assertTrue(n.valid_timestamp(stamp))

    def test_valid_offline_read_keeps_warning_and_marks_cloud_success(self):
        self.monitor.poll()
        saved = self.path.read_text()
        self.client.online = False
        self.now += 100
        self.assertEqual(self.monitor.poll(), 1)
        self.assertEqual(self.monitor.cloud_reads[DEVICE["id"]], self.now)
        self.assertEqual(self.path.read_text(), saved)

    def test_partial_purifier_status_still_sends_known_warning(self):
        device = dict(DEVICE, model="zhimi.airp.cpa4")
        self.monitor.config = dict(CONFIG, devices=[device])
        self.client.status = status("motorStuck")
        self.assertEqual(self.monitor.poll(), 0)
        self.assertEqual(len(self.client.sent), 1)
        self.assertIsNone(self.monitor.cloud_reads[device["id"]])

    def test_test_endpoint_error_does_not_block_physical_device(self):
        self.monitor.config = dict(CONFIG, testDeviceId="endpoint")
        original = self.client.api
        for invalid in [None, {"components": None}, {"components": {"main": {"earthpanel38939.latestAlert": []}}}]:
            with self.subTest(invalid=invalid):
                self.client.api = lambda path: invalid if "/endpoint/" in path else original(path)
                self.assertEqual(self.monitor.poll(), 1)
        def failed_endpoint(path):
            if "/endpoint/" in path:
                raise n.RequestError(503)
            return original(path)
        self.client.api = failed_endpoint
        self.assertEqual(self.monitor.poll(), 1)
        self.assertEqual(len(self.client.sent), 1)

    def test_invalid_test_timestamp_is_not_saved_or_pushed(self):
        config = dict(CONFIG, testDeviceId="endpoint")
        monitor = n.Monitor(config, self.path, self.client, lambda: self.now)
        original = self.client.api
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": {
            "value": "직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.", "timestamp": "\ud800"}}}}}
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        self.assertEqual(monitor.poll(), 1)
        self.assertNotIn("test:endpoint", monitor.state)
        self.assertIsNone(monitor.cloud_reads["endpoint"])
        self.assertEqual([sent[1] for sent in self.client.sent], [DEVICE["id"]])

    def test_test_timestamp_regression_and_equivalent_timezone_do_not_repeat_push(self):
        config = dict(CONFIG, testDeviceId="endpoint")
        monitor = n.Monitor(config, self.path, self.client, lambda: self.now)
        self.client.status = status("noFault")
        original = self.client.api
        reading = {"value": "historical", "timestamp": "2026-09-11T11:00:00Z"}
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": reading}}}}
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        monitor.poll()
        reading.update(value="직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.", timestamp="2026-09-11T11:01:00Z")
        monitor.poll()
        self.now += 30
        reading["timestamp"] = "2026-09-11T11:00:00Z"
        monitor.poll()
        self.assertEqual(monitor.state["test:endpoint"], "2026-09-11T11:01:00Z")
        self.assertEqual(monitor.cloud_reads["endpoint"], 1000)
        reading["timestamp"] = "2026-09-11T20:01:00+09:00"
        monitor.poll()
        self.assertEqual(len(self.client.sent), 1)

    def test_older_test_reading_does_not_cancel_a_pending_test(self):
        config = dict(CONFIG, testDeviceId="endpoint")
        monitor = n.Monitor(config, self.path, self.client, lambda: self.now)
        self.client.status = status("noFault")
        original = self.client.api
        reading = {"value": "historical", "timestamp": "2026-09-11T11:00:00Z"}
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": reading}}}}
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        monitor.poll()
        reading.update(value="직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.", timestamp="2026-09-11T11:01:00Z")
        self.client.fail = True
        monitor.poll()
        pending = monitor.retry["test:endpoint"]
        reading.update(value="historical", timestamp="2026-09-11T11:00:00Z")
        monitor.poll()
        self.assertEqual(monitor.retry["test:endpoint"], pending)
        reading.update(value="unrelated", timestamp="2026-09-11T11:02:00Z")
        monitor.poll()
        self.assertNotIn("test:endpoint", monitor.retry)

    def test_deep_json_response_is_isolated_to_affected_device(self):
        config = dict(CONFIG, devices=[DEVICE, dict(DEVICE, id="second")])
        monitor = n.Monitor(config, self.path, self.client, lambda: self.now)
        original = self.client.api
        self.client.api = lambda path: n.request_json("https://unused.example.test") if "/dehumidifier/status" in path else original(path)
        body = b'{"components":' + b'[' * 1200 + b'0' + b']' * 1200 + b'}'
        with patch.object(n.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value = io.BytesIO(body)
            self.assertEqual(monitor.poll(), 1)
        self.assertEqual([sent[1] for sent in self.client.sent], ["second"])
        self.assertIsNone(monitor.cloud_reads[DEVICE["id"]])

    def test_state_write_failure_retains_memory_dedup_and_retries_save(self):
        second = dict(DEVICE, id="second")
        self.monitor.config = dict(CONFIG, devices=[DEVICE, second])
        self.monitor.cloud_reads[second["id"]] = None
        with patch.object(n, "save_json", side_effect=OSError("disk full")):
            self.assertEqual(self.monitor.poll(), 2)
            self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.assertTrue(self.monitor.state_dirty)
        self.assertFalse(self.monitor.health(2)["stateSaved"])
        self.assertFalse(self.path.exists())
        self.monitor.poll()
        self.assertFalse(self.monitor.state_dirty)
        self.assertEqual(json.loads(self.path.read_text()), self.monitor.state)
        n.Monitor(self.monitor.config, self.path, self.client).poll()
        self.assertEqual(len(self.client.sent), 2)

    def test_test_endpoint_state_write_failure_does_not_block_other_device(self):
        self.monitor.config = dict(CONFIG, testDeviceId="endpoint")
        original = self.client.api
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": {
            "value": "historical", "timestamp": "2026-09-11T11:00:00Z"}}}}}
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        with patch.object(n, "save_json", side_effect=OSError("disk full")):
            self.assertEqual(self.monitor.poll(), 1)
        self.assertEqual(len(self.client.sent), 1)
        self.assertTrue(self.monitor.state_dirty)

    def test_test_endpoint_push_backoff_success_and_cancel(self):
        self.monitor.config = dict(CONFIG, testDeviceId="endpoint")
        original = self.client.api
        request = {"components": {"main": {"earthpanel38939.latestAlert": {"message": {
            "value": "historical", "timestamp": "2026-09-11T11:00:00Z"}}}}}
        self.client.api = lambda path: request if "/endpoint/" in path else original(path)
        self.monitor.poll()
        reading = request["components"]["main"]["earthpanel38939.latestAlert"]["message"]
        reading.update(value="직접 알림 테스트 요청입니다. 실제 기기 고장이 아닙니다.", timestamp="2026-09-11T11:01:00Z")
        self.client.fail = True
        self.monitor.poll()
        attempts = self.client.attempts
        self.monitor.poll()
        self.assertEqual(self.client.attempts, attempts)
        self.assertIn("test:endpoint", self.monitor.retry)
        self.assertEqual(self.monitor.health(1)["pendingRetries"], 1)
        self.now += 30
        self.client.fail = False
        self.monitor.poll()
        self.assertEqual(self.client.sent[-1][1], "endpoint")
        self.assertNotIn("test:endpoint", self.monitor.retry)
        reading["timestamp"] = "2026-09-11T11:02:00Z"
        self.client.fail = True
        self.monitor.poll()
        self.assertIn("test:endpoint", self.monitor.retry)
        reading.update(value="unrelated event", timestamp="2026-09-11T11:03:00Z")
        self.monitor.poll()
        self.assertNotIn("test:endpoint", self.monitor.retry)

    def test_failed_test_endpoint_remains_in_health_reads(self):
        config = dict(CONFIG, testDeviceId="endpoint")
        monitor = n.Monitor(config, self.path, self.client, lambda: self.now)
        original = self.client.api
        def failed_endpoint(path):
            if "/endpoint/" in path:
                raise n.RequestError(503)
            return original(path)
        self.client.api = failed_endpoint
        self.assertEqual(monitor.poll(), 1)
        self.assertIsNone(monitor.health(1)["deviceCloudReads"]["endpoint"])

    def test_return_to_saved_normal_cancels_pending_warning(self):
        self.client.status = status("noFault")
        self.monitor.poll()
        self.client.status = status("waterFull")
        self.client.fail = True
        self.monitor.poll()
        self.assertTrue(self.monitor.retry)
        self.client.status = status("noFault")
        self.monitor.poll()
        self.assertEqual(self.monitor.retry, {})

    def test_retry_caps_at_fifteen_minutes(self):
        self.client.fail = True
        expected_delays = [30, 60, 120, 240, 480, 900, 900]
        for delay in expected_delays:
            self.monitor.poll()
            pending = self.monitor.retry[DEVICE["id"] + ":fault"]
            self.assertEqual(pending[2], delay)
            self.now += delay

    def test_empty_devices_produce_explicit_empty_health(self):
        monitor = n.Monitor(dict(CONFIG, devices=[]), self.path, self.client, lambda: self.now)
        self.assertEqual(monitor.poll(), 0)
        self.assertEqual(monitor.health(0)["deviceCloudReads"], {})

    def test_health_write_failure_does_not_exit_main_loop(self):
        home = Path(self.tmp.name)
        n.save_json(home / "config.json", CONFIG)
        n.save_json(home / "auth.json", {"accessToken": "token", "refreshToken": "refresh", "expiresAt": 9999999999})
        original = n.save_json
        def save(path, data):
            if Path(path).name == "health.json":
                raise OSError("disk full")
            return original(path, data)
        with patch("sys.argv", ["notifier.py", "--home", str(home), "--once"]), \
             patch.object(n, "Client", return_value=self.client), \
             patch.object(n.signal, "signal"), patch.object(n, "save_json", side_effect=save):
            n.main()
        self.assertEqual(len(self.client.sent), 1)


class AuthTests(unittest.TestCase):
    def test_oauth_unauthorized_is_not_retried_as_a_device_api_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"auth.json"
            n.save_json(path,{"accessToken":"old","refreshToken":"old-refresh","expiresAt":1})
            requests=[]
            def request(url,*args,**kwargs):
                requests.append(url)
                raise n.RequestError(401)
            auth=n.Auth(path,request,lambda:1000)
            with self.assertRaises(n.RequestError):
                n.Client(auth,request).api("/devices/example/status")
            self.assertEqual(requests,[n.TOKEN_URL])

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

    def test_invalid_oauth_response_preserves_credentials(self):
        baseline = {"access_token": "new", "refresh_token": "r2", "expires_in": 86400}
        invalids = [None, [], "token"]
        for field, values in [("expires_in", [None, True, [], {}, "invalid", "NaN", "inf", -1, 0, float("nan"), float("inf"), 10 ** 400]),
                              ("access_token", [None, [], {}, 42, True, "", "with space", "line\nbreak", "\x00", "\x1f", "\x7f", "tokené", "\ud800"]),
                              ("refresh_token", [None, [], {}, 42, True, "", "with space", "\x00", "\x7f", "tokené", "\ud800"])]:
            invalids.extend(dict(baseline, **{field: value}) for value in values)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            n.save_json(path, {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1})
            original = path.read_text()
            for invalid in invalids:
                with self.subTest(invalid=invalid):
                    auth = n.Auth(path, lambda *a, **k: invalid, lambda: 1000)
                    with self.assertRaises(n.RequestError):
                        auth.token()
                    self.assertEqual(path.read_text(), original)

    def test_numeric_string_and_short_lifetime_refresh_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            n.save_json(path, {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1})
            calls = []
            now = [1000]
            def request(*args, **kwargs):
                calls.append(args)
                return {"access_token": "new", "refresh_token": "r2", "expires_in": "60"}
            auth = n.Auth(path, request, lambda: now[0])
            self.assertEqual(auth.token(), "new")
            self.assertEqual(auth.token(), "new")
            now[0] += 53
            self.assertEqual(n.Auth(path, request, lambda: now[0]).token(), "new")
            self.assertEqual(len(calls), 1)
            now[0] += 1
            auth.token()
            self.assertEqual(len(calls), 2)

    def test_invalid_persisted_auth_is_rejected_explicitly(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            for data in [None, [], {}, {"accessToken": "old", "refreshToken": "r1", "expiresAt": "1"},
                         {"accessToken": "old", "refreshToken": "r1", "expiresAt": float("nan")},
                         {"accessToken": "old", "refreshToken": "r1", "expiresAt": 10 ** 400},
                         {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1, "refreshAt": 2}]:
                with self.subTest(data=data):
                    n.save_json(path, data)
                    with self.assertRaises(n.RequestError):
                        n.Auth(path)

    def test_rotated_token_write_failure_retries_persistence_before_api(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            n.save_json(path, {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1})
            requests = []
            def request(url, *args, **kwargs):
                requests.append(url)
                return ({"access_token": "new", "refresh_token": "r2", "expires_in": 86400}
                        if url == n.TOKEN_URL else {"ok": True})
            auth = n.Auth(path, request, lambda: 1000)
            client = n.Client(auth, request)
            with patch.object(n, "save_json", side_effect=OSError("disk full")):
                for _ in range(2):
                    with self.assertRaises(OSError):
                        client.api("/devices")
            self.assertEqual(requests, [n.TOKEN_URL])
            self.assertEqual(auth.data["refreshToken"], "r1")
            self.assertTrue(client.api("/devices")["ok"])
            self.assertEqual(requests, [n.TOKEN_URL, n.API + "/devices"])
            self.assertEqual(json.loads(path.read_text())["refreshToken"], "r2")

    def test_invalid_persisted_token_characters_are_rejected_before_api(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            for field in ["accessToken", "refreshToken"]:
                for token in ["\x00", "\x1f", "\x7f", "tokené", "\ud800"]:
                    with self.subTest(field=field, token=ascii(token)):
                        data = {"accessToken": "access", "refreshToken": "refresh", "expiresAt": 9999999999}
                        data[field] = token
                        path.write_text(json.dumps(data, ensure_ascii=True))
                        with self.assertRaises(n.RequestError):
                            n.Auth(path)

    def test_corrupt_transfer_metadata_is_rejected_before_token_rotation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            for transfer in [None, [], "invalid", {},
                             {"profile": "default", "refreshTokenHash": "0" * 64},
                             {"profile": "\ud800", "refreshTokenHash": "0" * 64},
                             {"profile": "dedicated", "refreshTokenHash": "invalid"}]:
                with self.subTest(transfer=ascii(transfer)):
                    data = {"accessToken": "access", "refreshToken": "refresh", "expiresAt": 1,
                            "cliTransfer": transfer}
                    path.write_text(json.dumps(data, ensure_ascii=True))
                    with self.assertRaises(n.RequestError):
                        n.Auth(path)

    def test_second_unauthorized_is_not_refreshed_again(self):
        class Auth:
            count = 0
            def token(self): return "token"
            def refresh(self): self.count += 1
        auth = Auth()
        def request(*args, **kwargs):
            raise n.RequestError(401)
        with self.assertRaises(n.RequestError):
            n.Client(auth, request).api("/devices")
        self.assertEqual(auth.count, 1)

    def test_unauthorized_refresh_failure_does_not_retry_api(self):
        class Auth:
            def token(self): return "token"
            def refresh(self): raise n.RequestError(503)
        calls = []
        def request(*args, **kwargs):
            calls.append(args)
            raise n.RequestError(401)
        with self.assertRaises(n.RequestError):
            n.Client(Auth(), request).api("/devices")
        self.assertEqual(len(calls), 1)


class RequestTests(unittest.TestCase):
    def test_scalar_truncated_and_non_utf8_body_normalized(self):
        for body in [b"null", b"[]", b"42", b'"text"', b'{"components":', b'\xff']:
            with self.subTest(body=body), patch.object(n.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value.__enter__.return_value = io.BytesIO(body)
                with self.assertRaises(n.RequestError):
                    n.request_json("https://unused.example.test")

    def test_body_read_network_errors_normalized(self):
        for error in [http.client.IncompleteRead(b"{", 5), http.client.RemoteDisconnected(),
                      ConnectionResetError(), TimeoutError(), OSError("socket closed")]:
            with self.subTest(error=error), patch.object(n.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value.__enter__.return_value.read.side_effect = error
                with self.assertRaises(n.RequestError):
                    n.request_json("https://unused.example.test")

    def test_deep_json_body_parse_error_is_normalized(self):
        body = b'{"components":' + b'[' * 1200 + b'0' + b']' * 1200 + b'}'
        with patch.object(n.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value = io.BytesIO(body)
            with self.assertRaises(n.RequestError):
                n.request_json("https://unused.example.test")

    def test_invalid_outbound_unicode_is_normalized_before_opening_connection(self):
        with patch.object(n.urllib.request, "build_opener") as opener:
            with self.assertRaises(n.RequestError):
                n.request_json("https://unused.example.test", "POST", {"title": "\ud800"})
            opener.assert_not_called()

    def test_http_status_is_preserved_and_redirect_is_disabled(self):
        with patch.object(n.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = n.urllib.error.HTTPError("https://unused.example.test", 429, "limited", {}, None)
            with self.assertRaises(n.RequestError) as raised:
                n.request_json("https://unused.example.test")
            self.assertEqual(raised.exception.status, 429)
            opener.assert_called_once_with(n.NoRedirect)


if __name__ == "__main__":
    unittest.main()
