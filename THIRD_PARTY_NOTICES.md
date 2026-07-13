# Third-Party Notices and Release Provenance

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is distributed under `GPL-3.0-only`; the project license is in [LICENSE](./LICENSE). Release packages also contain independently maintained software and data whose own terms continue to apply.

This document records what the current repository can prove offline. An item marked `VERIFIED` has exact source and license evidence plus locally packaged notice files enforced by the release audit. **The repository as a whole is not yet cleared for redistribution while any item remains `BLOCKED`.** Every blocked item must be resolved before publishing a binary release: obtain the authoritative license/copyright material for the exact locked artifact, preserve all required notices, record source provenance, satisfy any source-code obligations, and include the required files in the packaged application. A project URL or npm `license` field is not a substitute for the applicable license text.

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

### Noto Color Emoji — `VERIFIED`

- Version: `2.051`
- Packaged path: `src/renderer/src/assets/NotoColorEmoji.ttf`
- Project: https://github.com/googlefonts/noto-emoji
- Locked download: https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/fonts/NotoColorEmoji.ttf
- Release: tag `v2.051`; tag commit `8998f5dd683424a73e2314a8c1f1e359c19e8742`; https://github.com/googlefonts/noto-emoji/tree/v2.051
- Embedded font metadata: version `2.051`; build date `20250818`; build revision `e92753bfa55fd449e427d4d325f9c8c40408c74e`; `Copyright 2022 Google Inc.`
- Packaged payload: 10,673,480 bytes; SHA-256 `72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b`
- License: `OFL-1.1`; OFL file copyright `Copyright 2013 Google LLC`
- Packaged license: [`licenses/noto-color-emoji/OFL-1.1.txt`](./licenses/noto-color-emoji/OFL-1.1.txt), SHA-256 `ae5c450cf4361bb474aec3cf67ecaaf29c4134f821f4ac6127904e876d0f93c8`
- Upstream license: https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/LICENSE, SHA-256 `500bb1ccf43df7bbb522112f9133a52b16e1c35e809632f5d8609b179152de5b`
- Packaged-license normalization: Normalized one redundant blank line and one trailing ASCII space; the legal text is unchanged.
- Official release evidence: https://github.com/googlefonts/noto-emoji/releases/tag/v2.051
- Official font evidence: https://github.com/googlefonts/noto-emoji/blob/v2.051/fonts/NotoColorEmoji.ttf
- Official license evidence: https://github.com/googlefonts/noto-emoji/blob/v2.051/LICENSE
- Official version metadata: https://github.com/googlefonts/noto-emoji/blob/v2.051/NotoColorEmoji.tmpl.ttx.tmpl

The official `v2.051` license permits the unmodified font to be bundled with software when every copy retains the copyright notice and complete OFL-1.1 text. No Reserved Font Name is specified after the copyright statement in that license. The release tag commit identifies the upstream release tree; the separate embedded build revision identifies the exact revision recorded by the packaged font itself. AikoBox ships the font unmodified, preserves both the embedded `Copyright 2022 Google Inc.` metadata and the OFL file's `Copyright 2013 Google LLC` notice, and does not claim Google endorsement. The audit binds the exact font size and SHA-256 to the tagged release, parses the packaged TTF metadata offline, and requires the complete reviewed upstream license text to enter `app.asar`.

<!-- resource:sysproxy -->

### sysproxy-rs-opti — `BLOCKED`

- Version: `0.5.1 / release v0.1.0`
- Packaged path: `extra/sidecar/sysproxy.win32-x64-msvc.node`
- Project: https://github.com/mihomo-party-org/sysproxy-rs-opti
- Locked download: https://github.com/mihomo-party-org/sysproxy-rs-opti/releases/download/v0.1.0/sysproxy.win32-x64-msvc.node
- Packaged payload: 574,464 bytes; SHA-256 `f17d99976218cb32aab0cc150e4e0fd40bcc4b237cd8af9f184e0ce4703e4995`
- Release blocker: The local JavaScript shim declares MIT, but no license/copyright file or source revision tied to the packaged native .node binary is present.

The `src/native/sysproxy/package.json` MIT declaration applies to that shim's metadata; it is not evidence for the separately downloaded native binary.

## JavaScript and Electron dependencies

Run the offline audit from a complete frozen install:

```powershell
node scripts/audit-licenses.mjs
```

The audit compares all three runtime resources with the lock and this notice, then inventories production dependency metadata through `pnpm licenses list --prod --json`. At the current lock, the locally declared production license expressions are `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `GPL-3.0`, `ISC`, `MIT`, `Python-2.0`, and `Unlicense`.

Five exact installed-package cases have mechanical evidence:

- `agent-base@6.0.2`: installed `README.md`, 5,056 bytes, SHA-256 `f1425c3b72330fe4fb2aa5a2fb152e939bdf534692a32b5f0b38f74147b98556`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/agent-base-6.0.2/MIT.txt`](./licenses/npm/agent-base-6.0.2/MIT.txt), SHA-256 `b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4`.
- `base-64@1.0.0`: the installed package's root `LICENSE-MIT.txt` is a license file despite its hyphenated name; its exact 1,077 bytes, SHA-256 `483acb265f182907d1caf6cff9c16c96f31325ed23792832cc5d8b12d5f88c8a`, are packaged at [`licenses/npm/base-64-1.0.0/MIT.txt`](./licenses/npm/base-64-1.0.0/MIT.txt).
- `data-uri-to-buffer@4.0.1`: installed `README.md`, 2,926 bytes, SHA-256 `a7cc4332acfa1f9b6530e01aac77fefe74f2efa32579215fddaa473013f9a25c`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/data-uri-to-buffer-4.0.1/MIT.txt`](./licenses/npm/data-uri-to-buffer-4.0.1/MIT.txt), SHA-256 `3072ef4a004c4f92b37eae61cdc3e27225c0a7d2f5e144700e40b9c5a5a7a9b9`.
- `https-proxy-agent@5.0.1`: installed `README.md`, 4,761 bytes, SHA-256 `32f0856d2c43df7d05cca960fdee84e1e38ab545bd7b2186433dfa41aa90a712`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/https-proxy-agent-5.0.1/MIT.txt`](./licenses/npm/https-proxy-agent-5.0.1/MIT.txt), SHA-256 `b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4`.
- `@electron-internal/extract-zip@1.0.3`: installed `package.json`, 2,095 bytes, SHA-256 `45d97af150605251f517c98e14bf456dc780cfa9956794547cd3e57172927662`. It is an Electron installation helper, not an AikoBox runtime dependency; the release verifier requires `/node_modules/@electron-internal/extract-zip` to be absent from `app.asar` while Electron's own `LICENSE.electron.txt` and `LICENSES.chromium.html` remain beside the application.

Four installed production package roots still lack a complete reviewed license file or equivalent exact evidence: `@nodable/entities@2.2.0`, `byte-length@1.0.2`, `sysproxy-rs@0.4.0`, and `xml-naming@0.1.0`. A package metadata SPDX label or a README containing only the word `MIT` is not a verbatim license grant.

The audit intentionally exits nonzero while any runtime resource is `BLOCKED` or a production package lacks reviewed license evidence. `--allow-known-blockers` exists only for testing the audit itself and must never be used as a release gate.
