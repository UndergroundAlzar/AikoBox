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
- Release: tag `v1.13.14`; commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`; https://github.com/SagerNet/sing-box/releases/tag/v1.13.14
- Fixed source tree: https://github.com/SagerNet/sing-box/tree/25a600db24f7680ad9806ce5427bd0ab8afe1114
- Locked archive: 20,961,591 bytes; SHA-256 `f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341`
- Packaged payload: 45,403,136 bytes; SHA-256 `db0d779948214cf761011d154c3a5da36df20394fa01a9fc798f1dc39fe9d183`
- Upstream license: `GPL-3.0-or-later plus upstream name/association restriction`; `Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>`
- Packaged upstream notice: [`licenses/sing-box-1.13.14/LICENSE.upstream.txt`](./licenses/sing-box-1.13.14/LICENSE.upstream.txt), 791 bytes, SHA-256 `650d5e3b99a446fb38e820fa87a49562e0c79eab868fff58618ac487a58e554c`
- Exact upstream notice: https://raw.githubusercontent.com/SagerNet/sing-box/25a600db24f7680ad9806ce5427bd0ab8afe1114/LICENSE, SHA-256 `650d5e3b99a446fb38e820fa87a49562e0c79eab868fff58618ac487a58e554c`
- Release blocker: The exact upstream release, license notice, archive, and source revision are pinned, but the release payload still lacks a corresponding-source bundle and the complete license/notice inventory for the statically linked Go dependency graph.

The packaged upstream notice now fixes the exact license grant and additional name/association restriction to the release commit. AikoBox's root [`LICENSE`](./LICENSE) contains the complete GPLv3 text. These are necessary but do not alone satisfy the source and static-dependency obligations, so this resource remains blocked.

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
- Release: tag `v0.1.0`; commit `ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a`; https://github.com/mihomo-party-org/sysproxy-rs-opti/releases/tag/v0.1.0
- Fixed source tree: https://github.com/mihomo-party-org/sysproxy-rs-opti/tree/ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a
- Packaged payload: 574,464 bytes; SHA-256 `f17d99976218cb32aab0cc150e4e0fd40bcc4b237cd8af9f184e0ce4703e4995`
- Upstream license: `MIT`; `Copyright (c) 2022 zzzgydi`
- Packaged upstream license: [`licenses/sysproxy-rs-opti/MIT.txt`](./licenses/sysproxy-rs-opti/MIT.txt), 1,064 bytes, SHA-256 `e3dee6d5b240791312cd89333a5cc62e6f65be66bff8ab6903dc9a67bbe84263`
- Exact upstream license: https://raw.githubusercontent.com/mihomo-party-org/sysproxy-rs-opti/ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a/LICENSE, SHA-256 `e3dee6d5b240791312cd89333a5cc62e6f65be66bff8ab6903dc9a67bbe84263`
- Release blocker: The native release tag, payload SHA-256, source revision, and upstream MIT text are pinned, but that revision has no Cargo.lock and the packaged static Rust dependency graph still lacks a complete reproducible license/notice inventory.

The JavaScript loader in `src/native/sysproxy` is AikoBox-owned code under `GPL-3.0-only`, independently of the native module. Its installed `index.js` is 3,605 bytes with SHA-256 `bfa9d0f66702286ac824203b9c8add8b665ed6ae56082ee2479853ed94bc02f0`; the packaged project [`LICENSE`](./LICENSE) is 35,149 bytes with SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`. This local ownership evidence does not clear the separately downloaded native module.

## JavaScript and Electron dependencies

Run the offline audit from a complete frozen install:

```powershell
node scripts/audit-licenses.mjs
```

The audit compares all three runtime resources with the lock and this notice, then inventories production dependency metadata through `pnpm licenses list --prod --json`. At the current lock, the locally declared production license expressions are `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `GPL-3.0`, `ISC`, `MIT`, `Python-2.0`, and `Unlicense`.

Eight exact installed-package cases have mechanical evidence:

- `@nodable/entities@2.2.0`: installed `package.json`, 1,270 bytes, SHA-256 `6a025503d776124cd4371fcba8383afcc30a640c5783f96093f76f19ecb66241`, is byte-identical to https://raw.githubusercontent.com/nodable/val-parsers/1a2c08a483b5b6428f1b3d01974875c97f3b3953/Entity/package.json. Revision `1a2c08a483b5b6428f1b3d01974875c97f3b3953` provides the exact upstream MIT license at https://raw.githubusercontent.com/nodable/val-parsers/1a2c08a483b5b6428f1b3d01974875c97f3b3953/LICENSE; its exact 1,064 bytes are packaged at [`licenses/npm/nodable-entities-2.2.0/MIT.txt`](./licenses/npm/nodable-entities-2.2.0/MIT.txt), SHA-256 `750cb3fb6362804957ef52caaf9b5c824015be44d494637330d7cd8834d31d40`.
- `agent-base@6.0.2`: installed `README.md`, 5,056 bytes, SHA-256 `f1425c3b72330fe4fb2aa5a2fb152e939bdf534692a32b5f0b38f74147b98556`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/agent-base-6.0.2/MIT.txt`](./licenses/npm/agent-base-6.0.2/MIT.txt), SHA-256 `b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4`.
- `base-64@1.0.0`: the installed package's root `LICENSE-MIT.txt` is a license file despite its hyphenated name; its exact 1,077 bytes, SHA-256 `483acb265f182907d1caf6cff9c16c96f31325ed23792832cc5d8b12d5f88c8a`, are packaged at [`licenses/npm/base-64-1.0.0/MIT.txt`](./licenses/npm/base-64-1.0.0/MIT.txt).
- `data-uri-to-buffer@4.0.1`: installed `README.md`, 2,926 bytes, SHA-256 `a7cc4332acfa1f9b6530e01aac77fefe74f2efa32579215fddaa473013f9a25c`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/data-uri-to-buffer-4.0.1/MIT.txt`](./licenses/npm/data-uri-to-buffer-4.0.1/MIT.txt), SHA-256 `3072ef4a004c4f92b37eae61cdc3e27225c0a7d2f5e144700e40b9c5a5a7a9b9`.
- `https-proxy-agent@5.0.1`: installed `README.md`, 4,761 bytes, SHA-256 `32f0856d2c43df7d05cca960fdee84e1e38ab545bd7b2186433dfa41aa90a712`; its complete 1,108-byte MIT section is packaged verbatim at [`licenses/npm/https-proxy-agent-5.0.1/MIT.txt`](./licenses/npm/https-proxy-agent-5.0.1/MIT.txt), SHA-256 `b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4`.
- `sysproxy-rs@0.4.0`: the local JavaScript loader is AikoBox-owned `GPL-3.0-only` code. Its installed `index.js`, 3,605 bytes and SHA-256 `bfa9d0f66702286ac824203b9c8add8b665ed6ae56082ee2479853ed94bc02f0`, is bound to the packaged root [`LICENSE`](./LICENSE), SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
- `xml-naming@0.1.0`: installed `package.json`, 1,114 bytes, SHA-256 `b69775b228da8fb7f25c98f309bab65a3a27444a2fd6b96f6793ece74be1acdc`, is byte-identical to https://raw.githubusercontent.com/NaturalIntelligence/xml-naming/c0afc395948730bed124859d7fc7cccabe0aac8a/package.json. Revision `c0afc395948730bed124859d7fc7cccabe0aac8a` provides the exact upstream MIT license at https://raw.githubusercontent.com/NaturalIntelligence/xml-naming/c0afc395948730bed124859d7fc7cccabe0aac8a/LICENSE; its exact 1,077 bytes are packaged at [`licenses/npm/xml-naming-0.1.0/MIT.txt`](./licenses/npm/xml-naming-0.1.0/MIT.txt), SHA-256 `8e75fc0e776c62ccadb8178ece8d3daa9ba7601fb0a49b2dfb0ea9a7a5c0aa07`.
- `@electron-internal/extract-zip@1.0.3`: installed `package.json`, 2,095 bytes, SHA-256 `45d97af150605251f517c98e14bf456dc780cfa9956794547cd3e57172927662`. It is an Electron installation helper, not an AikoBox runtime dependency; the release verifier requires `/node_modules/@electron-internal/extract-zip` to be absent from `app.asar` while Electron's own `LICENSE.electron.txt` and `LICENSES.chromium.html` remain beside the application.

The third-party `byte-length@1.0.2` package has been replaced through the frozen pnpm override with the AikoBox-owned, tested compatibility package at `src/native/byte-length`, version `1.0.2-aikobox.1`; it ships its own complete MIT license. No installed production package root currently lacks a complete reviewed license file or equivalent exact evidence.

The audit intentionally exits nonzero while any runtime resource is `BLOCKED` or a production package lacks reviewed license evidence. `--allow-known-blockers` exists only for testing the audit itself and must never be used as a release gate.
