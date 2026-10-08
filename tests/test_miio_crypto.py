"""Compare the hub's pure-Lua AES against an independent host implementation."""
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import unittest

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r'''
package.path = 'xiaomi-miio/src/?.lua;' .. package.path
local aes = require 'miio.aes'
local json = require 'dkjson'
local function unhex(s)
  return (s:gsub('..', function(b) return string.char(tonumber(b, 16)) end))
end
local function hex(s)
  return (s:gsub('.', function(b) return string.format('%02x', b:byte()) end))
end
local output = {}
for _, row in ipairs(assert(json.decode(io.read('*a')))) do
  local key, iv = unhex(row.key), unhex(row.iv)
  if row.mode == 'packet' then
    local packet = require 'miio.packet'
    local raw = packet.build(key, row.did, row.stamp, unhex(row.plain))
    local did, stamp, plain, err = packet.parse(key, unhex(row.cipher))
    output[#output + 1] = {cipher = hex(raw), plain = plain and hex(plain),
      did = did, stamp = stamp, error = err}
  else
    local method = row.mode == 'encrypt' and aes.encrypt_cbc or aes.decrypt_cbc
    local ok, value, err = pcall(method, key, iv, unhex(row.input))
    output[#output + 1] = {ok = ok, value = ok and value and hex(value),
      error = ok and err or (not ok and tostring(value) or nil)}
  end
end
print(json.encode(output))
'''


def lua_crypto(rows):
    process = subprocess.run(['lua', '-e', SCRIPT], input=json.dumps(rows),
                             text=True, capture_output=True, cwd=ROOT, timeout=10)
    if process.returncode:
        raise AssertionError(process.stderr)
    return json.loads(process.stdout)


def operation(mode, key, iv, value):
    return {'mode': mode, 'key': key.hex(), 'iv': iv.hex(), 'input': value.hex()}


class MiioCryptoTests(unittest.TestCase):
    def test_nist_aes128_cbc_known_answer(self):
        # NIST SP 800-38A F.2.1: four blocks, followed by our PKCS#7 block.
        key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        iv = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
        plain = bytes.fromhex(
            '6bc1bee22e409f96e93d7e117393172a'
            'ae2d8a571e03ac9c9eb76fac45af8e51'
            '30c81c46a35ce411e5fbc1191a0a52ef'
            'f69f2445df4f9b17ad2b417be66c3710')
        known = bytes.fromhex(
            '7649abac8119b246cee98e9b12e9197d5'
            '086cb9b507219ee95db113a917678b273'
            'bed6b8e3c1743b7116e69e222295163f'
            'f1caa1681fac09120eca307586e1a7')
        cipher = AES.new(key, AES.MODE_CBC, iv).encrypt(pad(plain, 16))
        self.assertEqual(cipher[:len(known)], known)
        encrypted, decrypted = lua_crypto([
            operation('encrypt', key, iv, plain), operation('decrypt', key, iv, cipher)])
        self.assertEqual(encrypted['value'], cipher.hex())
        self.assertEqual(decrypted['value'], plain.hex())

    def test_independent_oracle_at_block_boundaries_and_random_inputs(self):
        rng = random.Random(4820)
        lengths = list(range(66)) + [127, 128, 129, 255, 256, 257, 511, 512, 513,
                                    1023, 1024] + [rng.randrange(1025) for _ in range(128)]
        rows, expected = [], []
        for length in lengths:
            key, iv, plain = (rng.randbytes(size) for size in (16, 16, length))
            cipher = AES.new(key, AES.MODE_CBC, iv).encrypt(pad(plain, 16))
            rows.extend([operation('encrypt', key, iv, plain),
                         operation('decrypt', key, iv, cipher)])
            expected.extend([cipher.hex(), plain.hex()])
        results = lua_crypto(rows)
        self.assertEqual(len(results), len(expected))
        for index, (result, value) in enumerate(zip(results, expected)):
            with self.subTest(operation=index):
                self.assertTrue(result['ok'])
                self.assertEqual(result['value'], value)

    def test_invalid_padding_and_ciphertext_lengths_preserve_failure_contract(self):
        key, iv = bytes(range(16)), bytes(reversed(range(16)))
        bad_padded = [b'A' * 15 + b'\x00', b'A' * 15 + b'\x11',
                      b'A' * 14 + b'\x01\x02', b'A' * 13 + b'\x02\x03\x03']
        rows = [operation('decrypt', key, iv,
                          AES.new(key, AES.MODE_CBC, iv).encrypt(plain))
                for plain in bad_padded]
        rows.extend(operation('decrypt', key, iv, b'A' * size) for size in (0, 1, 15, 17))
        results = lua_crypto(rows)
        for result in results[:len(bad_padded)]:
            self.assertTrue(result['ok'], 'padding errors must return nil and an error')
            self.assertNotIn('value', result)
            self.assertIn('invalid padding', result['error'])
        for result in results[len(bad_padded):]:
            self.assertFalse(result['ok'], 'invalid block lengths must raise')
            self.assertIn('ciphertext must be', result['error'])

    def test_invalid_key_and_iv_lengths_preserve_failure_contract(self):
        rows = []
        for mode in ('encrypt', 'decrypt'):
            for size in (0, 15, 17):
                rows.extend([operation(mode, b'A' * size, b'B' * 16, b'C' * 16),
                             operation(mode, b'A' * 16, b'B' * size, b'C' * 16)])
        for result in lua_crypto(rows):
            self.assertFalse(result['ok'])
            self.assertIn('must be 16 bytes', result['error'])

    def test_miio_packet_against_independent_checksum_and_cipher(self):
        token = bytes(range(16))
        key = hashlib.md5(token).digest()
        iv = hashlib.md5(key + token).digest()
        plain = b'{"id":1,"result":[{"did":"power","code":0,"value":true}]}'
        encrypted = AES.new(key, AES.MODE_CBC, iv).encrypt(pad(plain + b'\0', 16))
        header = struct.pack('>HHIII', 0x2131, 32 + len(encrypted), 0, 123, 456)
        raw = header + hashlib.md5(header + token + encrypted).digest() + encrypted
        result, = lua_crypto([{'mode': 'packet', 'key': token.hex(), 'iv': iv.hex(),
                              'did': 123, 'stamp': 456, 'plain': plain.hex(), 'cipher': raw.hex()}])
        self.assertEqual(result['cipher'], raw.hex())
        self.assertEqual(result['plain'], plain.hex())
        self.assertEqual((result['did'], result['stamp']), (123, 456))
        self.assertNotIn('error', result)


if __name__ == '__main__':
    unittest.main()
