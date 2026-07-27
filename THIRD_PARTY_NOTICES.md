# Third-Party Notices and Release Provenance

AikoBox is derived from [Clash Party](https://github.com/mihomo-party-org/clash-party) and is distributed under `GPL-3.0-only`; the project license is in [LICENSE](./LICENSE). Release packages also contain independently maintained software and data whose own terms continue to apply.

This document records what the current repository can prove offline. An item marked `VERIFIED` has exact source and license evidence plus locally packaged notice files enforced by the release audit. **The repository as a whole is not yet cleared for redistribution while any item remains `BLOCKED`.** Every blocked item must be resolved before publishing a binary release: obtain the authoritative license/copyright material for the exact locked artifact, preserve all required notices, record source provenance, satisfy any source-code obligations, and include the required files in the packaged application. A project URL or npm `license` field is not a substitute for the applicable license text.

The Windows resource identities below come from `scripts/resources-lock.json`. The Android libbox identity is recorded separately from the actual arm64 AAR and embedded shared object. For files, SHA-256 identifies the packaged payload. For directory resources, the archive SHA-256 identifies the download and `AIKOBOX-DIR-SHA256-v1` identifies the normalized extracted tree.

## Locked runtime resources

<!-- resource:singBox -->

### sing-box — `VERIFIED`

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
- Pinned source identity: [`licenses/sing-box-1.13.14/go.mod`](./licenses/sing-box-1.13.14/go.mod), 9,387 bytes, SHA-256 `d0b353be0205774084936bae4114a2efa52381cd0860c704ff6172e4b8b50d2d` from https://raw.githubusercontent.com/SagerNet/sing-box/25a600db24f7680ad9806ce5427bd0ab8afe1114/go.mod; [`licenses/sing-box-1.13.14/go.sum`](./licenses/sing-box-1.13.14/go.sum), 39,961 bytes, SHA-256 `6bfa03cfa6f352a203c8bc077776112223f84c54ee5144fa0806932c4caae7ab` from https://raw.githubusercontent.com/SagerNet/sing-box/25a600db24f7680ad9806ce5427bd0ab8afe1114/go.sum
- Binary build-info inventory (read-only `go version -m extra/sidecar/sing-box.exe`): toolchain `go1.26.4`; main module `github.com/sagernet/sing-box` `v1.13.14`; 100 static `dep` entries; packaged at [`licenses/sing-box-1.13.14/buildinfo-modules.txt`](./licenses/sing-box-1.13.14/buildinfo-modules.txt), 10,271 bytes, SHA-256 `2d8d0819f63f2e5f54ab86d5c3775d49544189fa3df7f570f68f3ce379a03029`; TSV extract [`licenses/sing-box-1.13.14/static-modules.tsv`](./licenses/sing-box-1.13.14/static-modules.tsv), 9,668 bytes, SHA-256 `e926925f14833b3c358015eacfb7b27bdc6db609063f0be96ef74c50fb098e38`; bound to binary SHA-256 `db0d779948214cf761011d154c3a5da36df20394fa01a9fc798f1dc39fe9d183`
- Recorded build target: `GOOS=windows`, `GOARCH=amd64`, `CGO_ENABLED=0`, `-buildmode=exe`, with the exact 14 build tags preserved in the executable and generated build guide. The selected package graph contains no linked native archive.

[`scripts/license-windows-sing-box-release.mjs`](./scripts/license-windows-sing-box-release.mjs) dynamically generates the large corresponding-source and license assets in a caller-selected `--dist-dir`; those archives are intentionally not committed. The generator verifies the exact source tag/commit, binary hash, Go build identity, and committed 100-module inventory; runs `go mod verify` and `go mod vendor`; resolves the exact Windows package graph; downloads and checksum-verifies module source; and fails closed without archives if any actual module is absent from vendor, any vendor module lacks a legal file, a linked native input lacks corresponding source, or any recorded identity differs.

The verified graph covers all 100 modules recorded in the executable and all 159 modules produced by `go mod vendor`. All 159 vendor modules have collected `LICENSE`, `NOTICE`, `COPYING`, `COPYRIGHT`, `AUTHORS`, or equivalent legal material. Because the executable is CGO-disabled and the selected package graph has no linked native input, 41 unreferenced prebuilt native files found in module payloads are removed from the corresponding-source archive rather than represented as part of the executable.

**Every Windows Release containing this `sing-box.exe` must attach all four dynamically generated files:**

- `aikobox-sing-box-1.13.14-windows-amd64-corresponding-source.tar.gz`
- `aikobox-sing-box-1.13.14-windows-amd64-licenses.tar.gz`
- `aikobox-sing-box-1.13.14-windows-amd64-COVERAGE.json`
- `aikobox-sing-box-1.13.14-windows-amd64-SHA256SUMS.txt`

The source package contains the exact main source, complete generated vendor source, module/build evidence, and rebuild instructions. The separate license package contains the main GPL/upstream notices, all per-module legal files, the 100-module mapping, and its coverage report. Release upload is permitted by this evidence gate only when `releaseReady` is `true`, all counts match, `linkedNativeInputs` and `blockers` are empty, and the generated checksums are independently verified.

#### Android arm64 libbox evidence — `VERIFIED`

The Android application embeds a separately built libbox shared library from the same fixed sing-box release. This evidence is specific to the locally verified `libbox.aar`; it does not describe or clear the Windows executable above.

- Packaged APK path: `lib/arm64-v8a/libbox.so`; no other native ABI is present in the AAR.
- Source tag and commit: `v1.13.14`, `25a600db24f7680ad9806ce5427bd0ab8afe1114`.
- Build command from the exact clean checkout: `go run ./cmd/internal/build_libbox -target android -platform android/arm64`.
- Build tools: Go `1.24.7`; Android NDK `28.0.13004108`; `github.com/sagernet/gomobile/cmd/gomobile@v0.1.12`; `github.com/sagernet/gomobile/cmd/gobind@v0.1.12`.
- Actual AAR: 22,552,878 bytes; SHA-256 `cde14b0b16689901c46d786ee02ade397c65d1ee7df59931c9a2703ef3725a77`.
- Actual `libbox.so`: 63,239,528 bytes; SHA-256 `42c31593cd6e330f33e9711edd2fb0529d6b667359c29ac3296218752233dc5c`.
- Binary build information: [`licenses/sing-box-1.13.14/android-arm64/go-version-m.txt`](./licenses/sing-box-1.13.14/android-arm64/go-version-m.txt), 7,704 bytes, SHA-256 `b27a80e2a8570af21871df7dde7a5b7b16380f5acc2ed8bb0cb9e84fba09355a`. It records `go1.24.7`, `GOOS=android`, `GOARCH=arm64`, `CGO_ENABLED=1`, `-buildmode=c-shared`, the enabled build tags, and 75 static dependency entries.
- Android static module inventory: [`licenses/sing-box-1.13.14/android-arm64/android-arm64-static-modules.tsv`](./licenses/sing-box-1.13.14/android-arm64/android-arm64-static-modules.tsv), 6,775 bytes, SHA-256 `9cddfac88659d175cf283db36b4af17e875fe118b0f5e4b15e14e4506f58de8f`.
- Exact upstream license: [`licenses/sing-box-1.13.14/android-arm64/LICENSE.upstream.txt`](./licenses/sing-box-1.13.14/android-arm64/LICENSE.upstream.txt), 791 bytes, SHA-256 `650d5e3b99a446fb38e820fa87a49562e0c79eab868fff58618ac487a58e554c`.
- Fixed upstream source snapshot: [`licenses/sing-box-1.13.14/android-arm64/sing-box-v1.13.14-source-snapshot.tar.gz`](./licenses/sing-box-1.13.14/android-arm64/sing-box-v1.13.14-source-snapshot.tar.gz), 947,322 bytes, SHA-256 `95e274cf6fa33d1d5ab98352913d81571451eafe17026d04a3136d797c0cbc03`. This deterministic `git archive` is committed as compact provenance; the complete corresponding source is generated as a Release asset as described below.
- Android-specific notice: [`licenses/sing-box-1.13.14/android-arm64/NOTICE.txt`](./licenses/sing-box-1.13.14/android-arm64/NOTICE.txt), 2,101 bytes, SHA-256 `5773e6800c8b999c6d3889801cf6449848e452b011fdf7102270ff6229301709`.
- Linked native input: `github.com/sagernet/cronet-go/lib/android_arm64@v0.0.0-20260620135226-def9ff0fb992/libcronet.a`, 65,334,860 bytes, SHA-256 `88baecf52984daf0dd1ae7465d1f5820a6c6fa744d44703cd3198b7aec9c960b`.
- Native-source lock: [`licenses/sing-box-1.13.14/android-arm64/cronet-source-lock.json`](./licenses/sing-box-1.13.14/android-arm64/cronet-source-lock.json), 1,650 bytes, SHA-256 `dfb10257c0ad301ebd025468350246835f4d5a51912bd4c0238b8372e4f0f1b8`. It binds the native module commit `def9ff0fb992d0360f56ddbd4b43d65d29849771`, its declared build-source commit `98d539ce67568fb911654e66a14cf4247ed833ec`, NaiveProxy/Chromium source commit `888e114241c89b05fac4e4ee01482d7bd89ca15a`, and Chromium version `148.0.7778.96`.
- Locked Cronet build source: 135,783 bytes, SHA-256 `45de7d3506675941eddb24c9f4c685cbee3f4c2df651682238895886705351a3`; locked NaiveProxy/Chromium source: 52,001,385 bytes, SHA-256 `7a81f599734857ec5381c91a53e867ad5bf3e71fc26a75e3f86306834b84604d`.

The APK packages the following files under `assets/third_party/sing-box/`:

- `NOTICE.txt`: 2,101 bytes, SHA-256 `5773e6800c8b999c6d3889801cf6449848e452b011fdf7102270ff6229301709`.
- `LICENSE.upstream.txt`: 791 bytes, SHA-256 `650d5e3b99a446fb38e820fa87a49562e0c79eab868fff58618ac487a58e554c`.
- `GPL-3.0.txt`: 35,149 bytes, SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.

The compact committed evidence is reproducible with [`scripts/license-android-libbox.mjs`](./scripts/license-android-libbox.mjs). The script rejects the wrong source commit/tag, a modified source checkout, an unexpected AAR hash, any ABI other than `arm64-v8a`, a missing `libbox.so`, or incompatible Go build information; `--verify` regenerates the evidence in a temporary directory and compares it byte-for-byte with the committed files.

[`scripts/license-android-libbox-release.mjs`](./scripts/license-android-libbox-release.mjs) dynamically produces the large redistribution artifacts in a caller-selected `--dist-dir`; those archives are intentionally not committed. It verifies the exact source identity and AAR, runs `go mod verify` and `go mod vendor`, resolves the packages selected by the Android build tags, and fails closed before emitting archives unless all of the following are true:

1. The 75 modules recorded in the shipped `libbox.so` are exactly matched and covered.
2. Every module produced by `go mod vendor` has source and at least one collected `LICENSE`, `NOTICE`, `COPYING`, `COPYRIGHT`, `AUTHORS`, or equivalent legal file. The verified graph contains 159 vendor modules, all 159 covered.
3. Every native archive selected by the actual package graph is hash-matched to locked source. For this artifact, the sole linked archive is the Cronet input above; unreferenced native archives are removed from the source package rather than represented as linked.
4. The source package contains the exact sing-box source, complete generated vendor tree, module/build manifests, rebuild instructions, and locked Cronet/NaiveProxy source. The separate license package contains the main GPL and notice texts, per-module legal files, native-source legal files, and a machine-readable manifest.
5. The coverage report has `releaseReady: true` and an empty `blockers` array.

**Every Android Release must attach all four dynamically generated files:**

- `aikobox-libbox-1.13.14-android-arm64-corresponding-source.tar.gz`
- `aikobox-libbox-1.13.14-android-arm64-licenses.tar.gz`
- `aikobox-libbox-1.13.14-android-arm64-COVERAGE.json`
- `aikobox-libbox-1.13.14-android-arm64-SHA256SUMS.txt`

The checksums are intentionally generated for each Release output and must be verified before upload. The Android APK must continue to contain the three notice files listed above. This Android evidence applies only to the exact AAR and native-source lock; it does not substitute for the separately enforced Windows `sing-box.exe` evidence gate above or clear any other item marked `BLOCKED`.

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

### sysproxy-rs-opti — `VERIFIED`

- Version: `0.5.1 / upstream v0.1.0 / AikoBox reproducible build 1`
- Packaged path: `extra/sidecar/sysproxy.win32-x64-msvc.node`
- Pinned local source: `licenses/sysproxy-rs-opti/bin/sysproxy.win32-x64-msvc.node`
- Project: https://github.com/mihomo-party-org/sysproxy-rs-opti
- Release: tag `v0.1.0`; commit `ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a`; https://github.com/mihomo-party-org/sysproxy-rs-opti/releases/tag/v0.1.0
- Fixed source tree: https://github.com/mihomo-party-org/sysproxy-rs-opti/tree/ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a
- Self-built payload and pinned local source [`licenses/sysproxy-rs-opti/bin/sysproxy.win32-x64-msvc.node`](./licenses/sysproxy-rs-opti/bin/sysproxy.win32-x64-msvc.node): 583,680 bytes; SHA-256 `646d39126e25aa6d1d2b85741bc1994ad83d9470fbaccd021692d897686fd99a`
- Upstream license: `MIT`; `Copyright (c) 2022 zzzgydi`
- Packaged upstream license: [`licenses/sysproxy-rs-opti/MIT.txt`](./licenses/sysproxy-rs-opti/MIT.txt), 1,064 bytes, SHA-256 `e3dee6d5b240791312cd89333a5cc62e6f65be66bff8ab6903dc9a67bbe84263`
- Exact upstream license: https://raw.githubusercontent.com/mihomo-party-org/sysproxy-rs-opti/ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a/LICENSE, SHA-256 `e3dee6d5b240791312cd89333a5cc62e6f65be66bff8ab6903dc9a67bbe84263`
- Locked Rust dependency graph: [`licenses/sysproxy-rs-opti/Cargo.lock`](./licenses/sysproxy-rs-opti/Cargo.lock), 29,934 bytes, SHA-256 `1751a5f247d3a066845167ca149e7f4394b9e63c64b36159368eff271c655a98`.
- Production graph and legal provenance: 48 statically linked normal/build crates in [`licenses/sysproxy-rs-opti/rust-production-dependencies.tsv`](./licenses/sysproxy-rs-opti/rust-production-dependencies.tsv), 13,684 bytes, SHA-256 `43bc4697cf6dbb2e1c8942c7b7b5edeb736a57533c31997dfb851d90b617fea9`.
- Complete lockfile vendor inventory: 126 crates in [`licenses/sysproxy-rs-opti/rust-lock-vendor.tsv`](./licenses/sysproxy-rs-opti/rust-lock-vendor.tsv), 12,984 bytes, SHA-256 `b7d9fed5eb916cc17f4bd532ac43859f5aa2f5e649933b45ca16cd9be1cbbfa1`.
- Complete corresponding source: [`licenses/sysproxy-rs-opti/sysproxy-rs-opti-v0.1.0-windows-x64-corresponding-source.tar.gz`](./licenses/sysproxy-rs-opti/sysproxy-rs-opti-v0.1.0-windows-x64-corresponding-source.tar.gz), 30,037,359 bytes, SHA-256 `0ff42644b04fa62c4393a4f40b57f623ff025b4e2ea155bf8c1dfecba11546e4`. It contains the exact upstream tree, generated `Cargo.lock`, all 126 locked crate sources, registry checksums, Cargo offline configuration, both inventories, and build instructions.
- Complete dependency legal bundle: [`licenses/sysproxy-rs-opti/sysproxy-rs-opti-v0.1.0-windows-x64-license-notices.tar.gz`](./licenses/sysproxy-rs-opti/sysproxy-rs-opti-v0.1.0-windows-x64-license-notices.tar.gz), 25,961 bytes, SHA-256 `dc85f38e0a6c1746400551df07e02e50b49fddf481f6ece8f83de3ba1270a12d`. It includes every packaged production crate LICENSE/COPYING/NOTICE file. Six crates that omitted license files from their crates.io packages are bound to exact `.cargo_vcs_info.json` commits and exact upstream MIT texts under [`licenses/sysproxy-rs-opti/reviewed-license-overrides`](./licenses/sysproxy-rs-opti/reviewed-license-overrides).
- Reproducible build record: [`licenses/sysproxy-rs-opti/BUILD-INFO.txt`](./licenses/sysproxy-rs-opti/BUILD-INFO.txt), 1,517 bytes, SHA-256 `789a6333387e12f84abdd2f091b13cd99d04a01c52a7bcb2ffe115a1769e06a1`; Rust `1.97.1`, target `x86_64-pc-windows-msvc`, `SOURCE_DATE_EPOCH=1780791864`, `RUSTFLAGS=-C link-arg=/Brepro -C debuginfo=0 -C codegen-units=1 --remap-path-prefix=<SOURCE>=/usr/src/sysproxy-rs-opti --remap-path-prefix=<VENDOR>=/usr/src/cargo-vendor`, command `cargo +1.97.1 build --release --locked --offline --target x86_64-pc-windows-msvc`.
- Component notice: [`licenses/sysproxy-rs-opti/NOTICE.txt`](./licenses/sysproxy-rs-opti/NOTICE.txt), 963 bytes, SHA-256 `7b58521ba3799e49a8711824f1c701aaae95163cee4562debbe868c6ddfcf927`.
- Evidence lock: [`licenses/sysproxy-rs-opti/evidence-lock.json`](./licenses/sysproxy-rs-opti/evidence-lock.json), 5,105 bytes, SHA-256 `2dea8d9a0b7ba01f92da526f04fd4c434b19190a1bddc488f9d3722834553f7e`.

The upstream release binary is no longer packaged. AikoBox builds the fixed source itself and stores the reviewed result as a locked `local-file` resource. Two independent clean target directories produced byte-identical `.node` files; a third offline build from the committed corresponding-source archive is required by the verification procedure. [`scripts/license-sysproxy-rs-opti.mjs`](./scripts/license-sysproxy-rs-opti.mjs) fails closed on a changed commit or tag, dirty tracked source, unlocked Cargo graph, missing crate source/checksum/legal text, unreviewed legal override, unsafe archive path, wrong PE architecture, changed N-API exports, mismatched binary, or divergence from `scripts/resources-lock.json`.

The JavaScript loader in `src/native/sysproxy` remains AikoBox-owned code under `GPL-3.0-only`, independently of the verified native module. Its installed `index.js` is 3,605 bytes with SHA-256 `bfa9d0f66702286ac824203b9c8add8b665ed6ae56082ee2479853ed94bc02f0`; the packaged project [`LICENSE`](./LICENSE) is 35,149 bytes with SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.

## Android client (`mobile/`)

The Android client is not part of the Windows release payload, so its components are not
tracked by `scripts/resources-lock.json` or by `scripts/audit-licenses.mjs`. Its own lock
file is [`scripts/resources-lock.android.json`](./scripts/resources-lock.android.json), and
`scripts/verify-android-core.mjs` enforces the structural invariants before Gradle links
anything. No APK has been released; when one is, the same redistribution evidence this
document demands of the desktop payload must be gathered first.

**sing-box `libbox` binding — `BLOCKED`, same grounds as the desktop `sing-box` entry above.**

- Version `1.13.14`, built from tag `v1.13.14`, commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`
- Packaged path `mobile/android/app/libs/libbox.aar` → `lib/arm64-v8a/libbox.so` in the APK
- Built by [`.github/workflows/android-libbox.yml`](./.github/workflows/android-libbox.yml)
  with `go run ./cmd/internal/build_libbox -target android -platform android/arm64`
- Toolchain: `github.com/sagernet/gomobile@v0.1.12`, Android NDK `28.0.13004108`, Temurin JDK 17
- Upstream license: `GPL-3.0-or-later` plus the upstream name/association restriction, the
  same grant recorded at [`licenses/sing-box-1.13.14/LICENSE.upstream.txt`](./licenses/sing-box-1.13.14/LICENSE.upstream.txt)
- Release blocker: identical to the desktop entry — the binding statically links the same Go
  dependency graph, and no corresponding-source bundle or per-module license inventory has
  been assembled for it. Building from a pinned upstream tag advances provenance; it does not
  discharge GPLv3 §6.
- gomobile output is not bit-reproducible across hosts even with `-trimpath -buildvcs=false
-buildid=`, so the recorded SHA-256 identifies one build rather than constraining all of
  them. The invariants CI does enforce are the source tag, a single `arm64-v8a` ABI, and the
  presence of `jni/arm64-v8a/libbox.so`.

**Rejected alternative.** A third-party mirror publishing a prebuilt AAR
(`com.github.singbox-android:libbox`) was evaluated and rejected. It is an unaffiliated
account distributing an unreproducible binary with no signature and no checksum tied to an
upstream build, and it would run inside the VPN process with full visibility of the user's
traffic. Accepting it would also require an evidence record here that could not honestly be
filled in.

**Flutter and Dart dependencies.** Declared in [`mobile/pubspec.yaml`](./mobile/pubspec.yaml)
and resolved in `mobile/pubspec.lock`. The Flutter SDK and the first-party `flutter_*`,
`path_provider`, `shared_preferences`, `url_launcher` and `package_info_plus` packages are
BSD-3-Clause (Google); `flutter_riverpod`, `dynamic_color`, `material_color_utilities`,
`super_sliver_list`, `qr_flutter`, `app_links`, `file_picker`, `flutter_secure_storage`,
`http`, `web_socket_channel`, `yaml`, `yaml_edit`, `crypto` and `collection` are MIT or
BSD-3-Clause. `pubspec.lock` is the authoritative record; it is committed for exactly that
reason. The two first-party packages under `mobile/packages/` are part of this project and
carry its GPL-3.0 licence.

**Android platform dependencies.** `androidx.core:core-ktx` and
`org.jetbrains.kotlinx:kotlinx-coroutines-android`, both Apache-2.0.

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
