<p align="center">
  <img src="./build/aiko-mascot.png" width="180" alt="AikoBox mascot Aiko" />
</p>

<h1 align="center">AikoBox</h1>

<p align="center">
  A Windows-first sing-box desktop client with Clash YAML compatibility, verified core updates, rollback, and connectivity-safety protections.
</p>

<p align="center">
  <a href="./README.md">中文</a> · English
</p>

AikoBox targets **Windows 10/11 x64 only**. Its interface and subscription workflow are derived from Clash Party, while sing-box is the sole proxy core. Aiko, the white-haired and red-eyed mascot, represents the project.

> AikoBox is currently a `0.x` beta. Prereleases must pass the third-party redistribution audit and static artifact verification. Until a trusted Windows certificate is configured, a prerelease may ship only when it is clearly labeled as an unsigned beta.

## Highlights

- Imports Clash YAML subscriptions and converts them to sing-box JSON before startup.
- Supports common proxy protocols, `proxy-providers`, `rule-providers`, and the bundled Sub-Store workflow.
- Rejects unsafe conversion fallbacks instead of silently routing affected traffic directly.
- Provides explicit sing-box core updates with upstream SHA-256 verification, platform/version checks, candidate validation, and automatic rollback.
- Preserves the previous system-proxy state transactionally and keeps the core alive when Windows may still depend on its loopback endpoint.
- Uses a per-machine Program Files installer for TUN; portable and development builds are limited to system-proxy mode.
- Does not silently install application or core updates.

## Requirements

- Windows 10 or Windows 11, x64.
- System-proxy mode does not require administrator privileges.
- TUN is available only in the installed build and requires an explicit Windows elevation prompt.

## Build from source

Use Windows x64, Node.js 22+, and the pnpm version declared by the project:

```powershell
corepack enable
pnpm install --frozen-lockfile
node scripts/prepare.mjs --x64
pnpm run review
pnpm test
pnpm run build:win
```

`pnpm test` uses `sing-box check` for real configuration validation; it does not start the proxy service. Running `pnpm dev` does start the desktop application and core, so do not point it at ports used by another active proxy.

## Security and licensing

Read [SECURITY.md](./SECURITY.md) before reporting a vulnerability or sharing logs. Third-party provenance and unresolved redistribution requirements are tracked in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is licensed under [GPL-3.0](./LICENSE).
