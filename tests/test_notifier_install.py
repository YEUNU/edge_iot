import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "notification-service"))
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
        env_path = ROOT / "notification-service/.env"
        old_env = env_path.read_bytes() if env_path.exists() else None
        def restore_env():
            if old_env is None:
                env_path.unlink(missing_ok=True)
            else:
                env_path.write_bytes(old_env)
        self.addCleanup(restore_env)

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
        self.assertFalse((self.service / "notifier.py").exists())
        notifier.save_json(auth_path, {"accessToken": "rotated", "refreshToken": "rotated-r", "expiresAt": 9999999999})
        self.install()
        self.assertEqual(json.loads(auth_path.read_text())["refreshToken"], "rotated-r")

    def test_existing_auth_update_is_independent_of_unreadable_cli_credentials(self):
        self.install()
        auth_path = self.service / "auth.json"
        original_auth = auth_path.read_text()
        for invalid in ["broken JSON", "null", "[]"]:
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

    def test_special_data_directory_is_encoded_without_extra_env_entries(self):
        self.service = self.home / "Owner's \"알림\" $HOME ${XIAOMI_PATH_TEST}\\\nINJECTED=value\r\t\x1bend\\"
        self.install()
        lines = (self.service / ".env").read_text().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertTrue((self.service / "config.json").exists())
        self.assertEqual((self.service / ".env").stat().st_mode & 0o777, 0o600)

    def test_special_data_directory_round_trips_through_compose(self):
        docker = shutil.which("docker")
        if not docker:
            self.skipTest("Docker Compose CLI is not installed")
        version = subprocess.run([docker, "compose", "version"], capture_output=True)
        if version.returncode:
            self.skipTest("Docker Compose CLI is not installed")
        self.service = self.home / "Owner's \"알림\" $HOME ${XIAOMI_PATH_TEST}\\\nINJECTED=value\r\t\x1bend\\"
        self.install()
        result = subprocess.run([docker, "compose", "--project-directory", str(ROOT / "notification-service"),
                                 "--env-file", str(self.service / ".env"),
                                 "config", "--format", "json"], capture_output=True, check=True)
        model = json.loads(result.stdout)
        source = model["services"]["notifier"]["volumes"][0]["source"]
        self.assertEqual(source, str(self.service.resolve()).replace("$", "$$"))

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
