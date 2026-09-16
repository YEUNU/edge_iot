import subprocess
import sys
import unittest
from pathlib import Path


class LocalNetworkTest(unittest.TestCase):
    def test_allowlist_blocks_external_connections_before_network_io(self):
        bridge = Path(__file__).resolve().parents[1] / 'tuya-local' / 'bridge'
        script = '''
import socket, sys
from local_network import restrict_to_hub
restrict_to_hub('192.168.1.19')
for event, arguments in [
    ('socket.connect', (None, ('1.1.1.1', 443))),
    ('socket.connect', (None, ('192.168.1.19', 443))),
    ('socket.sendto', (None, b'x', ('1.1.1.1', 53))),
    ('socket.getaddrinfo', ('openapi.tuyaus.com', 443, 0, 0, 0)),
]:
    try:
        sys.audit(event, *arguments)
    except PermissionError:
        pass
    else:
        raise AssertionError(event + ' was allowed')
sys.audit('socket.connect', None, ('192.168.1.19', 6668))
# Incoming HTTP remains available; the policy only restricts outbound traffic.
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    server.listen(1)
print('local-only policy passed')
'''
        result = subprocess.run([sys.executable, '-c', script], cwd=bridge,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('local-only policy passed', result.stdout)
