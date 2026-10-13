import contextlib
import gzip
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('public_data_check',
    Path(__file__).resolve().parents[1] / 'scripts' / 'check_public_data.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class PublicDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fake_home = self.root / 'isolated-home'
        self.fake_home.mkdir()
        self.home_patch = patch.object(CHECK.Path, 'home', return_value=self.fake_home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        (self.root / '.gitignore').write_text('data/\n.state/\nisolated-home/\n.env\n')
        (self.root / 'data').mkdir()
        self.fake_secret = 'private-fixture-only-123456789'
        (self.root / 'data/config.json').write_text(json.dumps({'api_token': self.fake_secret}))

    def run_check(self, *args):
        stream = io.StringIO()
        with patch.object(CHECK, 'ROOT', self.root), patch.object(sys, 'argv', ['check', *args]), contextlib.redirect_stdout(stream):
            with self.assertRaises(SystemExit) as stopped:
                CHECK.main()
        self.assertNotIn(self.fake_secret, stream.getvalue())
        return stopped.exception.code, stream.getvalue()

    def test_ignored_local_secret_does_not_block_public_sources(self):
        (self.root / 'app.py').write_text('print("hello")\n')
        self.assertEqual(self.run_check()[0], 0)

    def test_force_added_private_file_is_blocked_in_index(self):
        subprocess.run(['git', '-C', self.root, 'add', '-f', 'data/config.json'], check=True)
        code, output = self.run_check('--staged')
        self.assertEqual(code, 1)
        self.assertIn('private runtime/export path', output)

    def test_compressed_secret_is_detected_without_echoing_it(self):
        (self.root / 'catalog.json.gz').write_bytes(gzip.compress(self.fake_secret.encode()))
        code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('known local private value', output)

    def test_private_field_spellings_and_numeric_did(self):
        cases = {
            'accessToken': 'fixture-access-only-12345',
            'refresh_token': 'fixture-refresh-only-12345',
            'token': 'fixture-token-only-12345',
            'did': 123456789,
            'localIP': '192.0.2.81',
            'localip': '192.0.2.82',
            'ip': '192.0.2.83',
            'mac': '02:00:00:00:00:01',
            'householdId': 'fixture-household-only',
            'testDeviceId': 'fixture-test-device-only',
        }
        for field, value in cases.items():
            with self.subTest(field=field):
                (self.root / 'data/auth.json').write_text(json.dumps({field: value}))
                (self.root / 'leak.txt').write_text(str(value))
                code, output = self.run_check()
                self.assertEqual(code, 1)
                self.assertIn('known local private value', output)
                self.assertNotIn(str(value), output)

    def test_device_id_in_notifier_devices_list(self):
        (self.root / 'data/config.json').write_text(json.dumps({'devices': [{'id': self.fake_secret}]}))
        (self.root / 'leak.txt').write_text(self.fake_secret)
        self.assertEqual(self.run_check()[0], 1)

    def test_public_oauth_client_and_ir_payload_are_not_private_values(self):
        value = 'public-catalog-fixture-only'
        (self.root / 'data/config.json').write_text(json.dumps({
            'clientId': value, 'irCode': value, 'id': value,
            'buttons': [{'id': value}],
        }))
        (self.root / 'public.txt').write_text(value)
        self.assertEqual(self.run_check()[0], 0)

    def test_default_external_cli_and_notifier_configs(self):
        for path in CHECK.default_private_configs():
            with self.subTest(file=path.name):
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.name == 'known_hubs.json':
                    value = '192.0.2.84'
                    payload = {value + ':9495': {'hostname': 'fixture'}}
                else:
                    value = self.fake_secret
                    payload = {'accessToken': value}
                path.write_text(json.dumps(payload))
                (self.root / 'leak.txt').write_text(value)
                code, output = self.run_check()
                self.assertEqual(code, 1)
                self.assertIn('known local private value', output)
                self.assertNotIn(value, output)
                path.unlink()

    def test_explicit_config_and_missing_config(self):
        source = self.fake_home / 'custom-settings.json'
        source.write_text(json.dumps({'device_id': self.fake_secret}))
        (self.root / 'data/config.json').write_text('{}')
        (self.root / 'leak.txt').write_text(self.fake_secret)
        self.assertEqual(self.run_check()[0], 0)
        self.assertEqual(self.run_check('--private-config', str(source))[0], 1)
        source.unlink()
        code, output = self.run_check('--private-config', str(source))
        self.assertEqual(code, 1)
        self.assertIn('private comparison source is missing', output)
        self.assertNotIn(str(source), output)

    def test_environment_provider_prefix_is_supported(self):
        value = '192.0.2.85'
        (self.root / '.env').write_text('TUYA_BIND_IP="' + value + '" # local binding\n')
        (self.root / 'leak.txt').write_text(value)
        code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('known local private value', output)
        self.assertNotIn(value, output)

    def test_ignored_audit_state_is_not_a_private_configuration_source(self):
        folder = self.root / '.state/audit'
        folder.mkdir(parents=True)
        value = 'synthetic-audit-fixture-only'
        (folder / 'auth.json').write_text(json.dumps({'accessToken': value}))
        (self.root / 'fixture.txt').write_text(value)
        self.assertEqual(self.run_check()[0], 0)

    def test_invalid_quoted_environment_secret_fails_closed(self):
        (self.root / '.env').write_text('API_TOKEN="' + self.fake_secret + '\n')
        code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('cannot read private comparison source', output)

    def test_index_scans_staged_blob_even_after_working_copy_is_cleaned(self):
        target = self.root / 'app.py'
        target.write_text(self.fake_secret)
        subprocess.run(['git', '-C', self.root, 'add', 'app.py'], check=True)
        target.write_text('clean')
        self.assertEqual(self.run_check()[0], 0)
        self.assertEqual(self.run_check('--staged')[0], 1)

    def test_corrupt_private_config_and_gzip_fail_without_value_output(self):
        (self.root / 'data/auth.json').write_text(self.fake_secret)
        (self.root / 'catalog.gz').write_bytes(self.fake_secret.encode())
        code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('cannot read private comparison source', output)
        self.assertIn('cannot read/decompress publishable file', output)

    def test_private_source_permission_error_fails(self):
        original_read = Path.read_text

        def read(path, *args, **kwargs):
            if path.name == 'config.json':
                raise PermissionError(self.fake_secret)
            return original_read(path, *args, **kwargs)

        with patch.object(Path, 'read_text', read):
            code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('cannot read private comparison source', output)

    def test_numeric_and_ip_substrings_do_not_match(self):
        self.assertFalse(CHECK.contains_private_value(b'1234567890', {b'123456789'}))
        self.assertFalse(CHECK.contains_private_value(b'192.0.2.100', {b'192.0.2.10'}))
        self.assertTrue(CHECK.contains_private_value(b'"did":123456789}', {b'123456789'}))

    def test_broken_symlink_checks_published_target_text(self):
        (self.root / 'link').symlink_to('/' + 'Users' + '/private-fixture/missing')
        code, output = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('personal home-directory path', output)

    def test_metadata_checks_author_and_committer_without_echoing_email(self):
        subprocess.run(['git', '-C', self.root, '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@users.noreply.github.com',
                        'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        self.assertEqual(self.run_check('--metadata')[0], 0)
        subprocess.run(['git', '-C', self.root, '-c', 'user.name=Fixture',
                        '-c', 'user.email=private-fixture@example.invalid',
                        'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        code, output = self.run_check('--metadata')
        self.assertEqual(code, 1)
        self.assertIn('non-noreply author/committer email', output)
        self.assertNotIn('private-fixture@example.invalid', output)
