# Mihomo Control for Windows

A lightweight native Windows controller for [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo).

> Unofficial community project. Not affiliated with MetaCubeX.

## Current status

The current pre-v1.0 baseline has completed runtime regression for:

- Proxy / TUN / Off switching
- single-core process exclusivity
- System Proxy synchronization
- watchdog failover
- performance-based switching
- private and public subscription import
- runtime subscription reload
- stable Mihomo update discovery
- SHA256-validated candidate update
- transactional install and rollback
- System Tray
- privacy-safe diagnostics

## Requirements

- Windows 10/11 x64
- .NET 10 Desktop Runtime or SDK
- Mihomo Windows amd64
- Administrator/UAC access for TUN mode

## Repository layout

```text
.
├─ src/
│  └─ MihomoControl/
├─ scripts/
├─ config/
├─ docs/
├─ Assets/
├─ .github/
│  └─ workflows/
├─ .gitignore
├─ LICENSE
├─ README.md
└─ SECURITY.md
```

## Privacy

Mihomo Control is designed so that support diagnostics do **not** include:

- subscription URLs
- UUIDs
- passwords or tokens
- private keys
- provider payloads
- runtime config contents
- logs

Do not post subscription URLs, credentials, or provider files in public issues.

## Runtime files

The public repository intentionally does not contain live runtime files such as:

- `subscription.txt`
- `providers/`
- `logs/`
- `backups/`
- `temp/`
- `watchdog-state.json`
- `mode.txt`
- live `config.yaml`
- live `config.tun.yaml`
- `mihomo.exe`

Use the sanitized examples under `config/` as a starting point.

## Building the UI

```powershell
dotnet build .\src\MihomoControl\MihomoControl.csproj -c Release
```

## Mihomo

Mihomo itself is maintained by MetaCubeX and is distributed under its own license.
This repository does not need to redistribute `mihomo.exe`; the controller can work with an official upstream build.

## Security

Please read [SECURITY.md](SECURITY.md) before reporting a security issue.

## License

MIT. See [LICENSE](LICENSE).
