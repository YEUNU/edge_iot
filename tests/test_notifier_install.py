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

    def install(self):
        argv = ["install.py", "--location", "home", "--device", "dehumidifier", "--prepare-only", "--data-dir", str(self.service)]
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


if __name__ == "__main__":
    unittest.main()
