# Android ARM64 release process

Android is built as a separate Flutter application under `apps/android` and is published by the
same tag-triggered workflow as the Windows packages. This document describes the release contract;
it does not assign the next version number.

## Fixed build inputs

The quality and release workflows reject toolchain drift:

- Flutter `3.44.4`
- OpenJDK `17`
- Go `1.24.7`
- Android compile SDK `36`
- Android build tools `36.0.0`
- Android NDK `28.0.13004108`
- sing-box/libbox `v1.13.14`, commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`
- sagernet gomobile and gobind `v0.1.12`
- application ID `com.aikobox.app`
- native ABI `arm64-v8a` only

Flutter downloads are checked against the SHA-256 in Google's official release metadata. The
libbox source checkout must exactly match the locked commit before the AAR is built.

## Required GitHub secrets

Every public Android APK, including a prerelease, requires the fixed release signing identity:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_CERTIFICATE_SHA256`

The workflow fails closed if any value is absent. It builds the release APK, aligns it, signs it
explicitly with Android Build Tools `apksigner`, and then verifies the finished APK against
`ANDROID_CERTIFICATE_SHA256`. A missing Gradle signing block or fallback key therefore cannot be
published. Keep an encrypted offline backup of the keystore and its credentials; losing this key
prevents in-place updates for existing GitHub APK installations.

## Version contract

For a tag `vX.Y.Z[-prerelease]`, all of the following must match:

- `package.json` version: `X.Y.Z[-prerelease]`
- Android `versionName`: `X.Y.Z[-prerelease]`
- release notes: `docs/releases/vX.Y.Z[-prerelease].md`
- Git tag: `vX.Y.Z[-prerelease]`

The workflow supplies the monotonically increasing GitHub workflow run number as Android
`versionCode`. A previously published tag must never be reused.

## Verification gates

The Android release job performs all of these checks before upload:

1. Flutter analysis and tests pass.
2. The libbox AAR has exactly one native library ABI and it is
   `jni/arm64-v8a/libbox.so`.
3. The APK signature is valid and has exactly the configured signing certificate SHA-256.
4. `applicationId`, `versionName`, and positive `versionCode` are valid.
5. Every APK native library is under `lib/arm64-v8a/`.
6. `lib/arm64-v8a/libbox.so` exists.
7. The APK SHA-256 exactly matches its sidecar.

The final publish job downloads both platform artifacts and recreates the aggregate checksum and
manifest. The public Release must contain exactly nine assets:

1. Windows x64 setup executable
2. Windows x64 portable executable
3. Android arm64-v8a APK
4. Three per-binary `.sha256` sidecars
5. `SHA256SUMS.txt`
6. `RELEASE-MANIFEST.txt`
7. `THIRD_PARTY-LICENSE-AUDIT.txt`

Publication is blocked if an unexpected, missing, stale, or duplicate asset changes this count.
