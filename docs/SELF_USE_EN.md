# Safe AikoBox self-use guide

This checklist is for first-time testing. Its goal is to preserve a recovery path if a profile is invalid, the app exits unexpectedly, or the network changes.

> AikoBox is still a beta. Keep your existing proxy/VPN, original subscription, and a known-good profile until AikoBox has been proven on your device.

## Windows: subscription URL

1. Download the Windows x64 installer or portable build from [GitHub Releases](https://github.com/UndergroundAlzar/AikoBox/releases).
2. Verify the matching `.sha256`. Current Windows betas are not Authenticode-signed and may trigger SmartScreen.
3. Keep the old proxy available, but avoid assigning both applications the same local ports.
4. Open AikoBox → Profiles → import the HTTPS subscription URL.
5. Wait for nodes. Treat timeout, authentication, invalid-content, and unsafe-redirect errors as failures; do not switch through an opaque error.
6. Select a node and enable ordinary system proxy first. Do not begin with TUN.
7. Verify browser and application connectivity.
8. Exit AikoBox and confirm that the Windows system proxy is restored and connectivity remains available.
9. Test elevated TUN only after the ordinary path is stable. The portable build does not support TUN.

A failed refresh should preserve the previous working profile where possible. Do not force an expired, unsafe, or sing-box-invalid candidate over a known-good configuration.

## Android: native sing-box JSON

1. Confirm that the device is ARM64 and runs Android 7.0 or newer.
2. Download the `arm64-v8a.apk` from GitHub Releases and verify its `.sha256`.
3. Confirm that the source is this repository. The fixed APK certificate SHA-256 is:
   `8896E81ED78BAACCD385DB95D4591FAA8EC7EF5A87D488258DBA53DA65276B94`
4. Import **native sing-box JSON** from a local file, an HTTPS URL, or pasted text.
5. Validate the profile before granting Android VPN permission.
6. On Android 13 and newer, allow notifications so the ongoing notification and Stop action remain available.
7. Test Wi-Fi/mobile switching, screen lock, reconnect behavior, and an explicit stop.

The current Android Release does not support Clash YAML, subscription URIs, latency tests, per-app routing, or automatic subscription updates. Experimental features under `mobile/` are not capabilities of the public APK.

## Never do this

- Do not make AikoBox the only connectivity path before exit and restoration are proven.
- Do not publish complete subscription URLs in issues, screenshots, chats, or logs.
- Do not upload profiles containing node addresses, UUIDs, passwords, tokens, controller secrets, or personal paths.
- Do not disable antivirus, firewall, or Android security protections to reproduce a problem.
- Do not install AikoBox from third-party file hosts or repackaging sites.

For ordinary problems, use the [issue templates](https://github.com/UndergroundAlzar/AikoBox/issues/new/choose). Report security problems privately under [SECURITY.md](../SECURITY.md).
