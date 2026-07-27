# AikoBox Android native layer

This module targets Android API 24+, compiles and targets API 36, uses Java 17,
and packages only `arm64-v8a`.

The native core is intentionally not committed. Build sing-box v1.13.14 at
commit `25a600d`:

```powershell
go run ./cmd/internal/build_libbox -target android -platform android/arm64
Copy-Item .\libbox.aar <AikoBox>\apps\android\android\app\libs\libbox.aar
```

Gradle stops at `preBuild` with a detailed error when the AAR is absent. The
Kotlin implementation follows `experimental/libbox/platform.go` from that
sing-box revision, not the newer SFA interface.

Flutter communicates over `com.aikobox.app/vpn` with these methods:

- `prepareVpn()`
- `checkProfile({ profilePath })`
- `start({ profilePath })`
- `reload({ profilePath })`
- `stop()`
- `getStatus()`
