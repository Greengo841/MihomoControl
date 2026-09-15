# Security Policy

## Reporting a vulnerability

Please do not include sensitive runtime data in a public issue.

Never post:

- subscription URLs
- UUIDs
- usernames or passwords
- API tokens
- private keys
- provider file contents
- live `config.yaml` / `config.tun.yaml`
- logs that may contain credentials

For ordinary bugs, use the application's `Copy diagnostics` output when possible. It is intentionally limited to operational state and excludes subscription/provider/config contents.

If a security issue cannot be described safely without revealing a secret, redact the secret before sharing details.

## Scope

Security-relevant areas include:

- subscription handling
- updater download and checksum verification
- process privilege boundaries
- TUN elevation
- rollback behavior
- local REST controller access
- public-release packaging

## Supported versions

Until the first stable release, only the latest published pre-v1.0 build is supported.
