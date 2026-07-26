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

AikoBox uses sing-box as its sole proxy core. The desktop client targets **Windows 10/11 x64**, with an interface and subscription workflow derived from Clash Party; the mobile client targets **Android arm64-v8a**, with an interface derived from FlClash. Aiko, the white-haired and red-eyed mascot, represents the project.

> AikoBox is currently a `0.x` beta. Prereleases must pass the third-party redistribution audit and static artifact verification. Until a trusted Windows certificate is configured, a prerelease may ship only when it is clearly labeled as an unsigned beta.

## Self-use quick start (subscription links only)

If you only use subscription URLs, read [docs/SELF_USE.md](./docs/SELF_USE.md):

1. **Keep your existing proxy** until AikoBox works
2. Import the subscription URL → wait for nodes
3. Enable **ordinary system proxy** (not TUN first) → select a node
4. Exit the app and confirm the system can still reach the internet

## Highlights

- Imports Clash YAML subscriptions and converts them to sing-box JSON before startup.
- Supports common proxy protocols, `proxy-providers`, and `rule-providers`.
- Rejects unsafe conversion fallbacks instead of silently routing affected traffic directly.
- Provides explicit sing-box core updates with upstream SHA-256 verification, platform/version checks, candidate validation, and automatic rollback.
- Preserves the previous system-proxy state transactionally and keeps the core alive when Windows may still depend on its loopback endpoint.
- Uses a per-machine Program Files installer for TUN; portable and development builds are limited to system-proxy mode. No macOS, Linux, Windows on ARM, or 32-bit desktop build.
- Does not silently install application or core updates.

## Requirements

**Desktop (Windows)**

- Windows 10 or Windows 11, x64.
- System-proxy mode does not require administrator privileges.
- TUN is available only in the installed build and requires an explicit Windows elevation prompt.

**Mobile (Android)**

- Android 7.0 (API 24) or newer, **arm64-v8a**. No armeabi-v7a, no x86.
- VPN permission is required. On Android 13 and newer, notification permission is required as well, or the ongoing notification — and the Stop button inside it — never appears.
- There is no system-proxy mode: on Android the VPN is both the system proxy and the TUN device.

**No APK has been released.** The source builds (see [Android client](#android-client)) and CI produces an unsigned arm64-v8a artifact for every commit, but that exists for developer verification only — no release signing key is configured, so it must not be installed or distributed as a release.

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

## Android client

Source lives in [`mobile/`](./mobile): Flutter 3.44 plus the sing-box `libbox` binding, **arm64-v8a only** (no armeabi-v7a, no x86). The visual language follows [FlClash](https://github.com/chen08209/FlClash)'s Material You design.

The desktop client's non-negotiables carry over one for one: traffic is never exposed before the core proves healthy, a candidate configuration is validated while the old core is still serving, a last-known-good configuration is kept and restored automatically when a candidate is rejected, and the app refuses to degrade silently to a direct connection when a profile cannot be converted safely. The Windows-specific mechanisms — WinINET system proxy, UAC elevation, tray — do not apply; `VpnService` replaces them, because on Android the VPN is both the system proxy and the TUN device.

The core does not update with the app. `libbox.aar` is built from `SagerNet/sing-box v1.13.14` source by [`.github/workflows/android-libbox.yml`](./.github/workflows/android-libbox.yml), pinned in [`scripts/resources-lock.android.json`](./scripts/resources-lock.android.json), and checked by `scripts/verify-android-core.mjs` before Gradle links it. SagerNet publishes no prebuilt AAR. A third-party mirror exists and is deliberately **not** used: it is an unaffiliated account's unreproducible binary that would run inside the VPN process with full visibility of the user's traffic.

Building locally requires Flutter 3.44.8, Android SDK 36, NDK r28 and JDK 17:

```powershell
# Produce the core binding first (needs Go 1.25+ and the SagerNet gomobile fork)
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
go run ./cmd/internal/build_libbox -target android -platform android/arm64   # inside the sing-box repo
copy libbox.aar <AikoBox>\mobile\android\app\libs\libbox.aar

cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

The converter and the subscription parser are pure Dart packages, tested on their own:

```powershell
cd mobile\packages\aikobox_convert;      dart test
cd mobile\packages\aikobox_subscription; dart test
```

`aikobox_convert`'s tests run the real sing-box binary's `check` over their output and compare it byte for byte against a golden corpus emitted by the TypeScript implementation, so the two cannot drift apart.

## Security and licensing

Read [SECURITY.md](./SECURITY.md) before reporting a vulnerability or sharing logs. Third-party provenance and unresolved redistribution requirements are tracked in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is licensed under [GPL-3.0](./LICENSE).
