# Architecture notes

## Runtime separation

The development/public repository should remain separate from the live runtime installation.

Recommended local layout:

```text
C:\Mihomo
```

Live runtime only.

```text
E:\Dev\MihomoControl
```

Source repository only.

The public repository must never depend on copying private runtime data into Git.

## Protected runtime contracts

Before v1.0, the following behavior is considered frozen unless a regression proves a defect:

- Proxy / TUN / Off lifecycle
- one Mihomo core in an active mode
- one watchdog
- confirmed-failure failover
- separate 2x performance-switch rule
- subscription Test / Apply / runtime reload
- stable updater + SHA256 validation
- transactional install + rollback
- tray lifecycle
- privacy-safe diagnostics
