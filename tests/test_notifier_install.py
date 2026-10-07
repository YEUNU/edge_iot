import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("notifier", ROOT / "notification-service/notifier.py")
notifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notifier)
with patch.dict(sys.modules, notifier=notifier):
    spec = importlib.util.spec_from_file_location("installer", ROOT / "notification-service/install.py")
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.service = self.home / "Library/Application Support/Xiaomi Notifications"
        self.credentials = self.home / "Library/Application Support/@smartthings/cli/credentials.json"
        notifier.save_json(self.credentials, {
            "default:api.smartthings.com": {"accessToken": "default-unchanged"},
            "xiaomi-alerts:api.smartthings.com": {
                "accessToken": "dedicated-access", "refreshToken": "dedicated-refresh",
                "expires": "2026-09-12T11:00:00Z"},
        })
        self.device = {"deviceId": "dehumidifier", "deviceModel": "xiaomi.derh.13l",
                       "locationId": "home", "label": "제습기"}
        mask = os.umask(0o077)
        self.addCleanup(os.umask, mask)

    def install(self, profile=None):
        argv = ["install.py", "--location", "home", "--device", "dehumidifier", "--prepare-only", "--data-dir", str(self.service)]
        if profile is not None:
            argv.extend(["--auth-profile", profile])
        with patch.object(Path, "home", return_value=self.home), \
             patch.object(sys, "argv", argv), \
             patch.object(installer.shutil, "which", return_value="/example/docker"), \
             patch.object(installer.subprocess, "run", return_value=SimpleNamespace(stdout="", returncode=0)), \
             patch.object(installer, "Client") as client, \
             patch("builtins.print"):
            client.return_value.api.return_value = self.device
            installer.main()

    def test_wrong_location_cannot_create_runnable_configuration(self):
        self.device["locationId"] = "another-home"
        with self.assertRaises(SystemExit), patch("sys.stderr"):
            self.install()
        self.assertFalse((self.service / "config.json").exists())
        self.assertEqual(json.loads((self.service / "auth.json").read_text())["refreshToken"], "dedicated-refresh")

    def test_install_transfers_only_dedicated_login_and_preserves_rotated_auth_on_update(self):
        self.install()
        credentials = json.loads(self.credentials.read_text())
        self.assertEqual(credentials, {"default:api.smartthings.com": {"accessToken": "default-unchanged"}})
        auth_path = self.service / "auth.json"
        self.assertEqual(json.loads(auth_path.read_text())["refreshToken"], "dedicated-refresh")
        self.assertEqual(auth_path.stat().st_mode & 0o777, 0o600)
        env = (self.service / ".env").read_text()
        self.assertIn(f"NOTIFIER_UID={os.getuid()}", env)
        self.assertIn(str(self.service), env)
        self.assertTrue((self.service / "compose.yaml").exists())
        self.assertIn("!notifier.py", (self.service / ".dockerignore").read_text())
        notifier.save_json(auth_path, {"accessToken": "rotated", "refreshToken": "rotated-r", "expiresAt": 9999999999})
        self.install()
        self.assertEqual(json.loads(auth_path.read_text())["refreshToken"], "rotated-r")

    def test_failed_cli_removal_resumes_after_rotation_and_uses_original_profile(self):
        original_save = installer.save_json
        def save(path, data):
            if Path(path) == self.credentials:
                raise OSError("CLI credentials disk full")
            original_save(path, data)
        with patch.object(installer, "save_json", side_effect=save), self.assertRaises(OSError):
            self.install()
        auth_path = self.service / "auth.json"
        self.assertEqual(json.loads(auth_path.read_text())["cliTransfer"]["profile"], "xiaomi-alerts")
        auth = notifier.Auth(auth_path, lambda *a, **k: {
            "access_token": "rotated", "refresh_token": "rotated-r", "expires_in": 86400}, lambda: 1000)
        auth.refresh()
        self.assertIn("cliTransfer", json.loads(auth_path.read_text()))
        credentials = json.loads(self.credentials.read_text())
        credentials["other:api.smartthings.com"] = {"refreshToken": "other-refresh"}
        notifier.save_json(self.credentials, credentials)
        self.install(profile="other")
        credentials = json.loads(self.credentials.read_text())
        self.assertNotIn("xiaomi-alerts:api.smartthings.com", credentials)
        self.assertEqual(credentials["other:api.smartthings.com"]["refreshToken"], "other-refresh")
        self.assertEqual(credentials["default:api.smartthings.com"]["accessToken"], "default-unchanged")
        persisted = json.loads(auth_path.read_text())
        self.assertEqual(persisted["refreshToken"], "rotated-r")
        self.assertNotIn("cliTransfer", persisted)

    def test_new_cli_login_is_preserved_when_pending_transfer_resumes(self):
        original_save = installer.save_json
        def save(path, data):
            if Path(path) == self.credentials:
                raise OSError("CLI credentials disk full")
            original_save(path, data)
        with patch.object(installer, "save_json", side_effect=save), self.assertRaises(OSError):
            self.install()
        credentials = json.loads(self.credentials.read_text())
        credentials["xiaomi-alerts:api.smartthings.com"]["refreshToken"] = "independent-login"
        notifier.save_json(self.credentials, credentials)
        self.install()
        self.assertEqual(json.loads(self.credentials.read_text())["xiaomi-alerts:api.smartthings.com"]["refreshToken"],
                         "independent-login")
        auth = json.loads((self.service / "auth.json").read_text())
        self.assertEqual(auth["refreshToken"], "dedicated-refresh")
        self.assertNotIn("cliTransfer", auth)

    def test_failed_transfer_completion_save_can_resume_after_cli_removal(self):
        original_save = installer.save_json
        def save(path, data):
            if Path(path).resolve() == (self.service / "auth.json").resolve() and "cliTransfer" not in data:
                raise OSError("auth completion disk full")
            original_save(path, data)
        with patch.object(installer, "save_json", side_effect=save), self.assertRaises(OSError):
            self.install()
        self.assertNotIn("xiaomi-alerts:api.smartthings.com", json.loads(self.credentials.read_text()))
        self.assertIn("cliTransfer", json.loads((self.service / "auth.json").read_text()))
        self.install()
        self.assertNotIn("cliTransfer", json.loads((self.service / "auth.json").read_text()))

    def test_legacy_interrupted_transfer_removes_only_matching_selected_profile(self):
        notifier.save_json(self.service / "auth.json", {
            "accessToken": "dedicated-access", "refreshToken": "dedicated-refresh", "expiresAt": 9999999999})
        credentials = json.loads(self.credentials.read_text())
        credentials["another:api.smartthings.com"] = {"refreshToken": "dedicated-refresh"}
        notifier.save_json(self.credentials, credentials)
        self.install()
        credentials = json.loads(self.credentials.read_text())
        self.assertNotIn("xiaomi-alerts:api.smartthings.com", credentials)
        self.assertIn("another:api.smartthings.com", credentials)
        self.assertIn("default:api.smartthings.com", credentials)

    def test_existing_auth_update_is_independent_of_unreadable_cli_credentials(self):
        self.install()
        auth_path = self.service / "auth.json"
        original_auth = auth_path.read_text()
        for invalid in ["broken JSON", "null", "[]", '{"unused":' + '[' * 1200 + '0' + ']' * 1200 + '}']:
            with self.subTest(credentials=invalid):
                self.credentials.write_text(invalid)
                self.install()
                self.assertEqual(auth_path.read_text(), original_auth)
                self.assertEqual(self.credentials.read_text(), invalid)

    def test_malformed_api_metadata_cannot_create_configuration(self):
        for field, invalids in [("deviceModel", [None, [], {}]),
                                ("label", [None, [], {}, "", "\ud800"])]:
            for invalid in invalids:
                with self.subTest(field=field, value=ascii(invalid)):
                    self.device[field] = invalid
                    with self.assertRaises(SystemExit), patch("sys.stderr"):
                        self.install()
                    self.assertFalse((self.service / "config.json").exists())
            self.device[field] = "xiaomi.derh.13l" if field == "deviceModel" else "제습기"

    def test_invalid_data_dir_is_rejected_before_credentials_or_artifacts_change(self):
        original = self.credentials.read_text()
        valid_service = self.service
        for name in ["Owner's Notifications", "Notifications\ninvalid", "Notifications\rinvalid"]:
            with self.subTest(name=repr(name)):
                self.service = self.home / name
                with self.assertRaises(SystemExit), patch("sys.stderr"):
                    self.install()
                self.assertFalse(self.service.exists())
                self.assertEqual(self.credentials.read_text(), original)
                args = SimpleNamespace(auth_profile="xiaomi-alerts", device=["dehumidifier"],
                                       location="home", test_device=None)
                with self.assertRaises(SystemExit), patch("sys.stderr"), patch.object(Path, "home", return_value=self.home):
                    installer.prepare(self.service, args, argparse.ArgumentParser())
                self.assertFalse(self.service.exists())
                self.assertEqual(self.credentials.read_text(), original)
        self.service = valid_service
        self.install()

    def test_invalid_cli_credentials_do_not_poison_retries(self):
        baseline = json.loads(self.credentials.read_text())
        invalids = [None, [], {}, {"accessToken": 123, "refreshToken": "refresh", "expires": "2026-09-12T11:00:00Z"},
                    {"accessToken": "access", "refreshToken": "\ud800", "expires": "2026-09-12T11:00:00Z"}]
        for expiry in [None, 123, "invalid", "2026-09-12T11:00:00", "2026-02-30T11:00:00Z"]:
            invalids.append({"accessToken": "access", "refreshToken": "refresh", "expires": expiry})
        for invalid in invalids:
            with self.subTest(credentials=ascii(invalid)):
                data = dict(baseline)
                data["xiaomi-alerts:api.smartthings.com"] = invalid
                self.credentials.write_text(json.dumps(data, ensure_ascii=True))
                original = self.credentials.read_text()
                with self.assertRaises(SystemExit), patch("sys.stderr"):
                    self.install()
                self.assertFalse((self.service / "auth.json").exists())
                self.assertFalse((self.service / "config.json").exists())
                self.assertEqual(self.credentials.read_text(), original)
        notifier.save_json(self.credentials, baseline)
        self.install()


if __name__ == "__main__":
    unittest.main()
