import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("notifier_health", Path(__file__).resolve().parents[1] / "notification-service/healthcheck.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
spec = importlib.util.spec_from_file_location("notifier_for_health", Path(__file__).resolve().parents[1] / "notification-service/notifier.py")
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


def status(**changes):
    return dict({"lastPollAt": 1000, "lastCloudReadAt": 1000, "startedAt": 1000,
                 "deviceCloudReads": {"first": 1000, "second": 1000},
                 "pendingRetries": 0, "stateSaved": True}, **changes)


class HealthTests(unittest.TestCase):
    def test_monitor_partial_api_failure_is_reported_after_grace(self):
        now = [1000]
        failed = [True]
        devices = [{"id": name, "label": name, "model": "xiaomi.derh.13l"} for name in ("first", "second")]
        class Client:
            def api(self, path):
                if "/second/" in path and failed[0]:
                    raise n.RequestError(503)
                if path.endswith("/health"):
                    return {"state": "ONLINE"}
                return {"components": {"main": {"earthpanel38939.deviceFault": {
                    "fault": {"value": "noFault", "timestamp": "2026-09-11T11:00:00Z"}}}}}
        with tempfile.TemporaryDirectory() as tmp:
            monitor = n.Monitor({"devices": devices, "locationId": "home"}, Path(tmp) / "state.json", Client(), lambda: now[0])
            self.assertTrue(h.healthy(monitor.health(monitor.poll()), now[0]))
            now[0] += h.MAX_AGE
            self.assertFalse(h.healthy(monitor.health(monitor.poll()), now[0]))
            failed[0] = False
            self.assertTrue(h.healthy(monitor.health(monitor.poll()), now[0]))

    def test_partial_failure_expires_and_recovery_restores_health(self):
        data = status(lastPollAt=1119, lastCloudReadAt=1119,
                      deviceCloudReads={"first": 1119, "second": 1000})
        self.assertTrue(h.healthy(data, 1119))
        data.update(lastPollAt=1120, lastCloudReadAt=1120)
        data["deviceCloudReads"]["first"] = 1120
        self.assertFalse(h.healthy(data, 1120))
        data["deviceCloudReads"]["second"] = 1120
        self.assertTrue(h.healthy(data, 1120))

    def test_startup_grace_applies_to_each_never_read_device(self):
        data = status(lastPollAt=1119, deviceCloudReads={"first": 1119, "second": None})
        self.assertTrue(h.healthy(data, 1119))
        data["lastPollAt"] = 1120
        self.assertFalse(h.healthy(data, 1120))
        data["deviceCloudReads"]["second"] = 1120
        self.assertTrue(h.healthy(data, 1120))
        data = status(lastCloudReadAt=0, deviceCloudReads={"first": None, "second": None})
        self.assertTrue(h.healthy(data, 1000))

    def test_no_devices_is_unhealthy_without_startup_grace(self):
        self.assertFalse(h.healthy(status(deviceCloudReads={}), 1000))

    def test_pending_push_and_state_write_failure_are_unhealthy(self):
        for changes in [{"pendingRetries": 1}, {"pendingRetries": -1},
                        {"pendingRetries": False}, {"pendingRetries": 0.0},
                        {"stateSaved": False}, {"stateSaved": None}, {"stateSaved": "true"}]:
            with self.subTest(changes=changes):
                self.assertFalse(h.healthy(status(**changes), 1000))

    def test_backward_clock_and_future_reads_are_unhealthy(self):
        self.assertFalse(h.healthy(status(), 999))
        self.assertFalse(h.healthy(status(startedAt=1001), 1000))
        self.assertFalse(h.healthy(status(deviceCloudReads={"first": 1001}), 1000))

    def test_malformed_health_values_fail_closed(self):
        invalids = [None, [], 1, "health", {}, status(deviceCloudReads=None),
                    status(deviceCloudReads=[]), status(deviceCloudReads={"first": "1000"})]
        for field in ["lastPollAt", "startedAt"]:
            invalids.extend(status(**{field: value}) for value in [None, True, "1000", [], {}, float("nan"), float("inf"), 10 ** 400])
        invalids.extend(status(deviceCloudReads={"first": value}) for value in [True, [], {}, float("nan"), float("inf"), 10 ** 400])
        for invalid in invalids:
            with self.subTest(invalid=invalid):
                self.assertFalse(h.healthy(invalid, 1000))
        for now in [None, True, "1000", float("nan"), float("inf"), 10 ** 400]:
            with self.subTest(now=now):
                self.assertFalse(h.healthy(status(), now))

    def test_legacy_health_file_keeps_recent_read_check(self):
        legacy = {"lastPollAt": 1000, "lastCloudReadAt": 1000, "pendingRetries": 0}
        self.assertTrue(h.healthy(legacy, 1000))
        legacy["lastPollAt"] = 1120
        self.assertFalse(h.healthy(legacy, 1120))


if __name__ == "__main__":
    unittest.main()
