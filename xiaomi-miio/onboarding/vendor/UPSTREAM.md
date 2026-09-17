Source: https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor
Commit: c4db715dace9806e905153c2977608873e8ab7c9
License: MIT; see LICENSE.

Local formatting change: removed trailing whitespace from the CLI banner; behavior is unchanged.

Local dead-code cleanup: removed the unreferenced `signed_nonce_sec` and legacy
`generate_signature` helpers and their unused `hmac` import. The active encrypted
request signature path (`generate_enc_signature`) is unchanged. `readline` is
retained for its interactive input-editing side effect.
