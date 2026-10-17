import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_notifier import CONFIG, FakeClient, n, status


class ReminderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.json"
        self.client = FakeClient()
        self.now = 1000
        self.monitor = n.Monitor(CONFIG, self.path, self.client, lambda: self.now)

    def test_reminder_starts_exactly_24_hours_after_last_successful_push(self):
        self.monitor.poll()
        due = self.now + 86400
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"], {"waterFull": due})
        self.now = due - 1
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.now = due
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.assertTrue(self.client.sent[-1][2].startswith("다시 알려드려요. "))
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"], {"waterFull": due + 86400})
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.now = due + 86400
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 3)

    def test_restart_preserves_deadline_without_postponing_or_replaying(self):
        self.monitor.poll()
        due = self.now + 86400
        self.now += 43200
        restarted = n.Monitor(CONFIG, self.path, self.client, lambda: self.now)
        restarted.poll()
        self.assertEqual(len(self.client.sent), 1)
        self.assertEqual(restarted.state["dehumidifier:fault"]["remindAfter"]["waterFull"], due)
        self.now = due
        n.Monitor(CONFIG, self.path, self.client, lambda: self.now).poll()
        self.assertEqual(len(self.client.sent), 2)
        self.assertEqual(json.loads(self.path.read_text())["dehumidifier:fault"]["remindAfter"]["waterFull"],
                         self.now + 86400)

    def test_unknown_invalid_stale_offline_and_failed_reads_cannot_send_due_reminder(self):
        self.client.status = status(stamp="2026-09-11T11:01:00Z")
        self.monitor.poll()
        self.now += 86400
        due = self.now
        for reading in ({}, status("unknown", "2026-09-11T11:02:00Z"),
                        status(stamp="invalid"), status(stamp="2026-09-11T11:00:00Z")):
            self.client.status = reading
            self.monitor.poll()
        self.client.status = status(stamp="2026-09-11T11:01:00Z")
        self.client.online = False
        self.monitor.poll()
        self.client.online = True
        with patch.object(self.client, "api", side_effect=n.RequestError(503)):
            self.monitor.poll()
        self.assertEqual(self.client.attempts, 1)
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"]["waterFull"], due)
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)

    def test_alternating_faults_have_independent_deadlines_and_only_current_fault_reminds(self):
        self.client.status = status("sensorFault1")
        self.monitor.poll()
        first_due = self.now + 86400
        self.now += 60
        self.client.status = status("sensorFault2", "2026-09-11T11:01:00Z")
        self.monitor.poll()
        second_due = self.now + 86400
        self.assertEqual(len(self.client.sent), 2)
        self.now = first_due
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.client.status = status("sensorFault1", "2026-09-12T11:00:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 3)
        self.now = second_due
        self.client.status = status("sensorFault2", "2026-09-12T11:01:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 4)
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"],
                         {"sensorFault1": first_due + 86400, "sensorFault2": second_due + 86400})

    def test_failed_reminder_keeps_deadline_and_backoff_until_success_including_restart(self):
        self.monitor.poll()
        self.now += 86400
        due = self.now
        self.client.fail = True
        self.monitor.poll()
        self.assertEqual(self.client.attempts, 2)
        self.now += 29
        self.monitor.poll()
        self.assertEqual(self.client.attempts, 2)
        self.now += 1
        self.monitor.poll()
        self.assertEqual(self.client.attempts, 3)
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"]["waterFull"], due)
        self.assertEqual(self.monitor.retry["dehumidifier:fault"][1:], (self.now + 60, 60))
        self.client.fail = False
        self.now += 1
        restarted = n.Monitor(CONFIG, self.path, self.client, lambda: self.now)
        restarted.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.assertEqual(restarted.retry, {})
        self.assertEqual(restarted.state["dehumidifier:fault"]["remindAfter"]["waterFull"], self.now + 86400)

    def test_recovery_cancels_failed_reminder_and_next_warning_sends_immediately(self):
        self.monitor.poll()
        self.now += 86400
        self.client.fail = True
        self.monitor.poll()
        self.now += 1
        self.client.status = status("noFault", "2026-09-12T11:00:00Z")
        self.monitor.poll()
        self.assertEqual(self.monitor.retry, {})
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["notified"], [])
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"], {})
        self.client.fail = False
        self.client.status = status("waterFull", "2026-09-12T11:01:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 2)
        self.assertFalse(self.client.sent[-1][2].startswith("다시 알려드려요. "))
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"]["waterFull"], self.now + 86400)

    def test_legacy_and_malformed_deadlines_start_a_full_interval_without_startup_push(self):
        records = [
            {"value": "waterFull", "timestamp": "2026-09-11T11:00:00Z"},
            *({"value": "waterFull", "timestamp": "2026-09-11T11:00:00Z", "notified": ["waterFull"],
               "remindAfter": value} for value in (None, [], "invalid", {}, {"waterFull": None},
                                                   {"waterFull": True}, {"waterFull": "1000"},
                                                   {"waterFull": -1}, {"waterFull": []})),
        ]
        for record in records:
            with self.subTest(record=record), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "state.json"
                n.save_json(path, {"dehumidifier:fault": record})
                client = FakeClient()
                monitor = n.Monitor(CONFIG, path, client, lambda: self.now)
                monitor.poll()
                self.assertEqual(client.sent, [])
                self.assertEqual(monitor.state["dehumidifier:fault"]["remindAfter"], {"waterFull": self.now + 86400})
                self.assertEqual(json.loads(path.read_text()), monitor.state)
        # Nonfinite JSON is rejected on load. An in-memory malformed deadline
        # still must be normalized before it can corrupt the next state save.
        for value in (float("nan"), float("inf"), float("-inf")):
            self.monitor.state["dehumidifier:fault"] = {
                "value": "waterFull", "timestamp": "2026-09-11T11:00:00Z", "notified": ["waterFull"],
                "remindAfter": {"waterFull": value}}
            self.monitor.poll()
            self.assertEqual(self.client.sent, [])
            self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"], {"waterFull": self.now + 86400})

    def test_sustained_filter_rearm_removes_only_water_deadline(self):
        self.monitor.poll()
        self.now += 15
        self.client.status = status("filterClean", "2026-09-11T11:01:00Z")
        self.monitor.poll()
        filter_due = self.now + 86400
        for _ in range(20):
            self.now += 15
            self.monitor.poll()
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["notified"], ["filterClean"])
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"], {"filterClean": filter_due})
        self.client.status = status("waterFull", "2026-09-11T11:02:00Z")
        self.monitor.poll()
        self.assertEqual(len(self.client.sent), 3)
        self.assertFalse(self.client.sent[-1][2].startswith("다시 알려드려요. "))
        self.assertEqual(self.monitor.state["dehumidifier:fault"]["remindAfter"],
                         {"filterClean": filter_due, "waterFull": self.now + 86400})


if __name__ == "__main__":
    unittest.main()
