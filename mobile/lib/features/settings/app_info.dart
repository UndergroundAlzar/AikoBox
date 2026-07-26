/// Identity of the running build, for the About page and the per-app picker.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers.dart';

/// Version, build number and package name of this APK.
final FutureProvider<PackageInfo> appPackageInfoProvider =
    FutureProvider<PackageInfo>((Ref ref) => PackageInfo.fromPlatform());

/// The embedded sing-box version, straight from libbox.
///
/// Read over the method channel rather than from [coreStatusProvider] so the
/// About page can show it before the tunnel has ever been started.
final FutureProvider<String> coreVersionProvider = FutureProvider<String>(
  (Ref ref) => ref.watch(coreChannelProvider).coreVersion(),
);
