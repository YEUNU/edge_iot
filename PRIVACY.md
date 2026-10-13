# Publishing without household data

Never commit device credentials, account sessions, household device/location IDs,
raw cloud exports, packet captures, screenshots, or local runtime databases.
Keep local configuration and state in ignored `data/`, `state/`, `.state/`, or
`.env` files. Example files must contain placeholders. `.gitignore` does not
remove files already tracked by Git.

Before publishing:

```sh
python3 scripts/check_public_data.py
python3 scripts/check_public_data.py --staged
python3 scripts/check_public_data.py --staged --metadata
gitleaks git . --redact
```

The Python check scans tracked and publishable untracked working files, or the
entire Git index with `--staged`. It decompresses `.gz` catalogs, rejects private
runtime/export paths, and detects personal home-directory paths. Staged content
is read from Git, so cleaning a working file does not hide an already staged leak.

Known private values come from ignored runtime JSON configuration and `.env`
files. Supported JSON names include `config.json`, `auth.json`, `credentials.json`,
`cloud.json`, `devices.json`, `tinytuya.json`, `secrets.json`, `known_hubs.json`,
`ir-detail.json`, and `ac-detail.json`. The comparison recognizes camelCase and
snake_case tokens, keys, account/device/location/household IDs, numeric DIDs,
LAN addresses, MAC addresses, and device IDs in notification configuration.
Environment variables may have provider prefixes, including `TUYA_BIND_IP`.
Public OAuth client IDs and catalog button IDs/IR payloads are not collected as
credentials.

These external macOS configurations are also read when present:

- `~/Library/Application Support/@smartthings/cli/credentials.json`
- `~/Library/Application Support/@smartthings/cli/known_hubs.json`
- `~/Library/Application Support/Xiaomi Notifications/auth.json`
- `~/Library/Application Support/Xiaomi Notifications/config.json`

Use repeatable `--private-config PATH` options for private JSON or `.env` files in
other locations. `.state`, dependency directories, `tests`, and `fixtures` are
excluded from automatic comparison-source discovery: audit output and synthetic
fixtures are not authoritative configuration. Pass a trusted source there
explicitly if needed. Missing explicit sources, unreadable/invalid private JSON,
and unreadable/corrupt publishable files fail the check rather than being skipped.

The report prints file names and finding categories, never matching values or
configuration contents. External sources use numbered labels instead of personal
home paths. This is an exact-value comparison and complements a secret scanner;
neither proves that every possible personal detail has been detected. On a clean
clone, absent local configuration cannot supply comparison values.

Use the GitHub-provided `users.noreply.github.com` email for commits. `--metadata`
checks both author and committer emails in all reachable commits and reports
non-GitHub-noreply addresses without printing them. It does not inspect historical
file contents; run the Git secret scanner as well. Changing local Git
configuration does not remove addresses already stored in commit metadata.

Public SmartThings capability namespaces and presentation IDs are needed by the
published profiles. They identify integration definitions, not a household's
device, location, LAN address, or authentication key.
