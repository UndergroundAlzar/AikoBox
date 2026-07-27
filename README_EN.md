<p align="center">
  <img src="./build/aiko-mascot.png" width="180" alt="AikoBox mascot Aiko" />
</p>

<h1 align="center">AikoBox</h1>

<p align="center">
  A sing-box GUI client for Windows x64 and Android ARM64
</p>

<p align="center">
  <a href="https://github.com/UndergroundAlzar/AikoBox/actions/workflows/quality.yml"><img src="https://github.com/UndergroundAlzar/AikoBox/actions/workflows/quality.yml/badge.svg?branch=main" alt="Quality gate" /></a>
  <a href="https://github.com/UndergroundAlzar/AikoBox/releases"><img src="https://img.shields.io/github/v/release/UndergroundAlzar/AikoBox?include_prereleases&label=release" alt="Latest release" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/UndergroundAlzar/AikoBox" alt="GPL-3.0-only" /></a>
</p>

<p align="center">
  <a href="./README.md">中文</a> · English
</p>

<p align="center">
  <a href="https://github.com/UndergroundAlzar/AikoBox/releases">Download AikoBox</a>
  ·
  <a href="./docs/SELF_USE_EN.md">Safe self-use guide</a>
  ·
  <a href="https://github.com/UndergroundAlzar/AikoBox/issues">Report an issue</a>
</p>

AikoBox uses sing-box as its only proxy core. The Windows client accepts Clash YAML subscriptions and emphasizes safe system-proxy restoration, candidate validation, and rollback. The Android client runs a pinned `libbox` build through the system `VpnService`.

> [!WARNING]
> AikoBox is still a `0.x` beta. Windows prerelease executables currently have no trusted Authenticode signature and may trigger Unknown publisher or SmartScreen warnings. The Android APK is signed with the project's fixed release certificate. Keep an existing proxy and a configuration backup during initial testing; do not immediately make a beta your device's only connectivity path.

## Current support

| Capability                              | Windows x64     | Android arm64-v8a      |
| --------------------------------------- | --------------- | ---------------------- |
| Native sing-box JSON                    | Supported       | Supported              |
| Clash YAML and subscription URIs        | Supported       | Not yet                |
| Subscription management and auto-update | Supported       | Not yet                |
| Node latency tests                      | Supported       | Not yet                |
| Ordinary system proxy                   | Supported       | Not applicable         |
| TUN / system VPN                        | Installed build | Supported              |
| Per-app routing                         | Rule-based      | Not yet                |
| Safe update and rollback                | Supported       | Validate before switch |

The current public Android build focuses on running native sing-box JSON reliably. Clash conversion, subscription management, latency tests, per-app routing, and background subscription updates are planned. Features present only in experimental code are not advertised as released.

## Download

Download only from [GitHub Releases](https://github.com/UndergroundAlzar/AikoBox/releases).

### Windows

- `aikobox-windows-<version>-x64-setup.exe`: per-machine Program Files installer with system-proxy and TUN support; installation and TUN require elevation.
- `aikobox-windows-<version>-x64-portable.exe`: single-file portable build, limited to ordinary system-proxy mode.
- Both are currently explicit unsigned betas. The release workflow verifies the unsigned state and publishes SHA-256 checksums.

### Android

- `aikobox-android-<version>-arm64-v8a.apk`: Android 7.0 (API 24) or newer, ARM64 only.
- The APK uses a fixed release certificate. Certificate SHA-256:
  `8896E81ED78BAACCD385DB95D4591FAA8EC7EF5A87D488258DBA53DA65276B94`
- There is no Play Store, armeabi-v7a, x86, or x86_64 package.

Every binary has a matching `.sha256`. Each Release also contains a unified `SHA256SUMS.txt`, a build manifest, the third-party license audit, and corresponding source and license evidence for native components.

Verify a download in PowerShell:

```powershell
$file = '.\aikobox-windows-0.1.0-beta.3-x64-setup.exe'
$expected = ((Get-Content "$file.sha256") -split '\s+')[0]
$actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
$actual -ceq $expected
```

The result must be `True`. A checksum proves consistency with the release manifest; it does not replace a trusted download source or a code signature.

## Quick start

### Windows: subscription URL

1. Keep your existing proxy available.
2. Import the subscription URL and wait for nodes to appear.
3. Select a node and enable ordinary system proxy first; do not begin with TUN.
4. Verify normal websites and applications.
5. Exit AikoBox and confirm that the Windows system proxy is restored and connectivity remains available.

### Android: sing-box JSON

1. Install the ARM64 APK from Releases and allow VPN and notification permissions.
2. Import native sing-box JSON from a local file, an HTTPS URL, or pasted text.
3. Validate the profile, grant VPN permission, and connect.
4. Test Wi-Fi/mobile-network switching and stopping the VPN.

See the [safe self-use guide](./docs/SELF_USE_EN.md) for the complete checklist.

## Design principles

- **Fail closed:** reject unsafe conversion or validation failures instead of silently routing affected traffic directly.
- **Protect the working path:** validate candidates before switching and never pretend that proxy restoration or core shutdown succeeded.
- **Verifiable supply chain:** pin and audit sing-box, libbox, sysproxy, hashes, sources, and redistribution evidence.
- **No silent installation:** application and core updates require explicit user action.
- **Minimize secret exposure:** treat subscription URLs, credentials, controller secrets, and logs as sensitive.

## Requirements and limits

### Windows

- Windows 10 or Windows 11, x64.
- Ordinary system-proxy mode does not require administrator privileges.
- TUN is available only in the installed build and requires elevation.
- No macOS, Linux, Windows on ARM, or 32-bit Windows build.

### Android

- Android 7.0 (API 24) or newer, arm64-v8a.
- VPN permission is required. Android 13 and newer also require notification permission.
- The current release imports native sing-box JSON only. Clash YAML, subscription URIs, per-app routing, Quick Settings tiles, and start-at-boot are not promised.

## Source layout

- `src/`: Windows Electron client, Clash subscription handling, and sing-box conversion.
- `apps/android/`: the compact Android client used by current Releases.
- `mobile/`: an experimental next-generation Android client with broader UI and cross-platform conversion work; **it is not the current public APK**.

Do not mix the capabilities of the two Android trees. Only `apps/android/`, built and verified by `.github/workflows/release.yml`, enters the current GitHub Release.

## Local verification

Windows development requires Node.js 22 and the pnpm version declared by the repository:

```powershell
corepack enable
pnpm install --frozen-lockfile
node scripts/prepare.mjs --x64
pnpm run review
pnpm test
pnpm run build:win
```

The current Android release pipeline pins Flutter 3.44.4, JDK 17, Go 1.24.7, Android SDK 36, and NDK r28. Treat the [quality workflow](./.github/workflows/quality.yml) and [release workflow](./.github/workflows/release.yml) as the source of truth for libbox compilation, signing, ABI checks, and license verification.

## Roadmap

- Clash YAML and subscription URI conversion on Android
- Android subscription management and manual refresh
- Android node latency tests
- Android per-app routing
- Android background subscription updates
- Trusted Windows code signing

The roadmap states direction, not delivery dates.

## Security, contributing, and license

- Report security issues privately under [SECURITY.md](./SECURITY.md). Never publish subscriptions, tokens, or unredacted logs.
- Development and pull-request requirements are in [CONTRIBUTING.md](./CONTRIBUTING.md).
- Native component provenance and licenses are documented in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is licensed under [GPL-3.0-only](./LICENSE).
