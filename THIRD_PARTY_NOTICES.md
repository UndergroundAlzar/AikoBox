# Third-Party Notices and Release Provenance

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is distributed under `GPL-3.0-only`; the project license is in [LICENSE](./LICENSE). Release packages also contain independently maintained software and data whose own terms continue to apply.

This document records what the current repository can prove offline. **It is not yet a redistribution clearance.** Every item marked `BLOCKED` must be resolved before publishing a binary release: obtain the authoritative license/copyright material for the exact locked artifact, preserve all required notices, record source provenance, satisfy any source-code obligations, and include the required files in the packaged application. A project URL or npm `license` field is not a substitute for the applicable license text.

The resource identities below come from `scripts/resources-lock.json` and target Windows x64 only. For files, SHA-256 identifies the packaged payload. For directory resources, the archive SHA-256 identifies the download and `AIKOBOX-DIR-SHA256-v1` identifies the normalized extracted tree.

## Locked runtime resources

<!-- resource:singBox -->

### sing-box — `BLOCKED`

- Version: `1.13.14`
- Packaged path: `extra/sidecar/sing-box.exe`
- Project: https://github.com/SagerNet/sing-box
- Locked download: https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box-1.13.14-windows-amd64.zip
- Packaged payload: 45,403,136 bytes; SHA-256 `db0d779948214cf761011d154c3a5da36df20394fa01a9fc798f1dc39fe9d183`
- Release blocker: The packaged sing-box binary has no component copyright notice, exact license declaration, complete license text tied to this binary, or corresponding-source offer in the release payload.

The repository's root GPL text covers AikoBox itself. It must not be presented as proof of the exact sing-box binary's license or as satisfaction of that binary's attribution and source obligations without upstream evidence.

<!-- resource:notoColorEmoji -->

### Noto Color Emoji — `BLOCKED`

- Version: `2.051 (noto-emoji commit e92753bfa55fd449e427d4d325f9c8c40408c74e)`
- Packaged path: `src/renderer/src/assets/NotoColorEmoji.ttf`
- Project: https://github.com/googlefonts/noto-emoji
- Locked download: https://raw.githubusercontent.com/googlefonts/noto-emoji/e92753bfa55fd449e427d4d325f9c8c40408c74e/fonts/NotoColorEmoji.ttf
- Packaged payload: 10,673,480 bytes; SHA-256 `72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b`
- Release blocker: The packaged font has no accompanying upstream license text, copyright notice, or Reserved Font Name information in the release payload.

The commonly associated SIL Open Font License must be confirmed from the pinned upstream revision and shipped verbatim; this repository currently contains no such evidence.

<!-- resource:enableLoopback -->

### enableLoopback — `BLOCKED`

- Version: `1.4.3.0 (release commit 20bf1cb008dcc47d07b3affd17a806c253d53eab)`
- Packaged path: `extra/files/enableLoopback.exe`
- Distribution project: https://github.com/Kuingsmile/uwp-tool
- Mutable download locator: https://github.com/Kuingsmile/uwp-tool/releases/download/latest/enableLoopback.exe
- Packaged payload: 84,040 bytes; SHA-256 `f0c328376bd5ae0ef3b0eb19ac1f343c24a9abfe7bc1008d3b2f6ef3573d04d1`
- Local PE evidence: file/product version `1.4.3.0`; company `Progress Software Corporation`; copyright identifies Progress Software.
- Release blocker: The binary identifies Progress Software Corporation rather than the distribution repository. No local license grant proves that this exact Fiddler-derived binary may be redistributed.

The lock's `sourceCommit` is a review annotation, but the `latest` URL does not cryptographically bind that commit. SHA-256 fixes the payload identity; it does not grant redistribution rights. Obtain a license from the actual rights holder or replace/remove this helper.

<!-- resource:sysproxy -->

### sysproxy-rs-opti — `BLOCKED`

- Version: `0.5.1 / release v0.1.0`
- Packaged path: `extra/sidecar/sysproxy.win32-x64-msvc.node`
- Project: https://github.com/mihomo-party-org/sysproxy-rs-opti
- Locked download: https://github.com/mihomo-party-org/sysproxy-rs-opti/releases/download/v0.1.0/sysproxy.win32-x64-msvc.node
- Packaged payload: 574,464 bytes; SHA-256 `f17d99976218cb32aab0cc150e4e0fd40bcc4b237cd8af9f184e0ce4703e4995`
- Release blocker: The local JavaScript shim declares MIT, but no license/copyright file or source revision tied to the packaged native .node binary is present.

The `src/native/sysproxy/package.json` MIT declaration applies to that shim's metadata; it is not evidence for the separately downloaded native binary.

<!-- resource:trafficMonitor -->

### TrafficMonitor plus MihomoParty plugin — `BLOCKED`

- Version: `TrafficMonitor 1.8.5.1 + MihomoParty plugin 1.0.0.0`
- Packaged directory: `extra/files/TrafficMonitor`
- Distribution project: https://github.com/mihomo-party-org/mihomo-party-run
- Locked download: https://github.com/mihomo-party-org/mihomo-party-run/releases/download/monitor/x64.zip
- Archive: 589,842 bytes; SHA-256 `1d0d74fc203984ba67c77ebcc5aa403b9e515b2f0a9b8e9ca5d966429dd05b18`
- Extracted tree: 3 files; directory SHA-256 `a350462cc46f4f70eec14a0e3e0a029530fe225fb4ce7ddb762f578175fafac6`
- Child identities: `TrafficMonitor.exe` SHA-256 `f66245201835678ffd7f6c06e9a08a05f0a3f82cf5113039fe90bcadca26bf80`; `plugins/MihomoParty.dll` SHA-256 `3b6a09787b2d715c43fe0c7670be525a5fb6bb175da2123ad6a8f5bf30820e6c`.
- Release blocker: The archive contains TrafficMonitor.exe and MihomoParty.dll but no license, copyright notice file, source revisions, or corresponding-source information for either binary.

Local PE metadata attributes `TrafficMonitor.exe` to ZhongYang and `MihomoParty.dll` to Mihomo Party. Their separate upstream projects and exact license versions must be recorded; one aggregate download URL does not establish either binary's rights.

<!-- resource:subStoreBackend -->

### Sub-Store backend — `BLOCKED`

- Version: `2.34.0`
- Packaged path: `extra/files/sub-store.bundle.cjs`
- Project: https://github.com/sub-store-org/Sub-Store
- Locked download: https://github.com/sub-store-org/Sub-Store/releases/download/2.34.0/sub-store.bundle.js
- Packaged payload: 3,030,709 bytes; SHA-256 `7deaa5a24b5626e1120be65109b36e9457e45b00c0687e2670e55511188f1d42`
- Release blocker: The generated bundle preserves some dependency comments but no locally verifiable top-level license grant, full required license set, copyright inventory, or corresponding source record is shipped.

Generated comments are useful evidence but do not replace complete license texts or the project's own license grant. Preserve the upstream bundle unchanged and add the exact release's source and notice material.

<!-- resource:subStoreFrontend -->

### Sub-Store Front-End — `BLOCKED`

- Version: `2.28.5`
- Packaged directory: `extra/files/sub-store-frontend`
- Project: https://github.com/sub-store-org/Sub-Store-Front-End
- Locked download: https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/2.28.5/dist.zip
- Archive: 2,424,499 bytes; SHA-256 `1fae258b7797110d5da0a672e6466b94af5bbe3f4e0ecf07bb3191090a633633`
- Extracted tree: 160 files; directory SHA-256 `8e732156c12e29f36ddf864e3c0739e2ef2de3d4c5180bc8e8aeead0b0de6ff8`
- Release blocker: The extracted frontend directory has no top-level license, dependency notices, copyright inventory, or source revision tied to the locked release archive.

## JavaScript and Electron dependencies

Run the offline audit from a complete frozen install:

```powershell
node scripts/audit-licenses.mjs
```

The audit compares all seven runtime resources with the lock and this notice, then inventories production dependency metadata through `pnpm licenses list --prod --json`. At the current lock, the locally declared production license expressions are `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `GPL-3.0`, `ISC`, `MIT`, `Python-2.0`, and `Unlicense`.

Nine installed production package roots declare a license in metadata but contain no root `LICENSE`, `LICENCE`, `COPYING`, or `NOTICE` file: `@electron-internal/extract-zip@1.0.3`, `@nodable/entities@2.2.0`, `agent-base@6.0.2`, `base-64@1.0.0`, `byte-length@1.0.2`, `data-uri-to-buffer@4.0.1`, `https-proxy-agent@5.0.1`, `sysproxy-rs@0.4.0`, and `xml-naming@0.1.0`. Resolve their verbatim notice requirements from the exact upstream revisions instead of reconstructing terms from SPDX labels alone.

Metadata is only an inventory: before release, generate and package the complete dependency notices/license texts and review license compatibility. Electron distributions separately carry `LICENSE.electron.txt` and `LICENSES.chromium.html`; verify those files remain in the packaged runtime.

The audit intentionally exits nonzero while any runtime resource is `BLOCKED` or a production package lacks a root license file. `--allow-known-blockers` exists only for testing the audit itself and must never be used as a release gate.
