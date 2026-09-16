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
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        (self.root / '.gitignore').write_text('data/\n')
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
