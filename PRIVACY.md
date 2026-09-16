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
gitleaks git . --redact
```

The Python check also inspects decompressed catalog files and compares against
known private values in local commissioning configuration. It prints file names
and finding categories, never the private value. It complements a secret scanner;
neither proves that all possible personal information has been detected.

Use the GitHub-provided `users.noreply.github.com` email for new commits. Existing
commit author metadata is part of Git history; changing local Git configuration
does not remove addresses from old commits. Rewriting published history requires
coordination and a separate decision.

Public SmartThings capability namespaces and presentation IDs are needed by the
published profiles. They identify integration definitions, not a household's
device, location, LAN address, or authentication key.
