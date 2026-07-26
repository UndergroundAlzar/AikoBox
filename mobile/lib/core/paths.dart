/// On-disk layout, mirroring the desktop's `src/main/utils/dirs.ts`.
///
/// ```
/// <appSupport>/config.json                 user settings           (app_config.dart)
/// <appSupport>/profile.yaml                profile index           (profile_store.dart)
/// <appSupport>/profiles/<id>.yaml          profile content         (profile_store.dart)
/// <appSupport>/profiles/<id>.http.json     conditional-GET cache   (profile_store.dart)
/// <appSupport>/work/sing-box*.json         core config slots       (config_store.dart)
/// <appSupport>/work/config*.yaml           Clash runtime slots     (config_store.dart)
/// ```
///
/// The desktop keeps settings as YAML; Android keeps them as JSON, because the
/// only writer is this app and JSON needs no third-party emitter.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A profile id has to be safe to paste into a file name. Same rule as the
/// desktop's `assertSafeProfileId`.
final RegExp _safeProfileId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Throws when [id] could escape the profiles directory.
void assertSafeProfileId(String id) {
  if (!_safeProfileId.hasMatch(id) || id == '.' || id == '..') {
    throw ArgumentError.value(id, 'id', 'Invalid profile id');
  }
}

/// Generates the desktop's profile-id shape: hex milliseconds since the epoch.
String newProfileId() =>
    DateTime.now().millisecondsSinceEpoch.toRadixString(16);

/// Resolved application directories.
class AikoDirs {
  const AikoDirs(this.dataDir);

  static AikoDirs? _cached;
  static Future<AikoDirs>? _pending;

  /// Resolves the directories once per process and reuses the result.
  ///
  /// Safe to call from anywhere; concurrent callers share one resolution.
  static Future<AikoDirs> ensure() {
    final cached = _cached;
    if (cached != null) return Future<AikoDirs>.value(cached);
    return _pending ??= _resolve().then((dirs) {
      _cached = dirs;
      _pending = null;
      return dirs;
    });
  }

  /// The already-resolved directories, or `null` before [ensure] has completed.
  static AikoDirs? get cached => _cached;

  /// Points the whole core layer at [directory]. Tests use this to work in a
  /// temp dir; production never calls it.
  static void overrideForTesting(Directory? directory) {
    _cached = directory == null ? null : AikoDirs(directory);
    _pending = null;
  }

  static Future<AikoDirs> _resolve() async {
    final support = await getApplicationSupportDirectory();
    final dirs = AikoDirs(support);
    await dirs.createAll();
    return dirs;
  }

  /// `/data/data/<pkg>/files` on Android — private, not world-readable, and not
  /// swept by the media scanner.
  final Directory dataDir;

  Directory get profilesDir => Directory(p.join(dataDir.path, 'profiles'));

  /// Where the core's config slots live.
  Directory get workDir => Directory(p.join(dataDir.path, 'work'));

  File get appConfigFile => File(p.join(dataDir.path, 'config.json'));

  File get profileConfigFile => File(p.join(dataDir.path, 'profile.yaml'));

  File profileFile(String id) {
    assertSafeProfileId(id);
    return File(p.join(profilesDir.path, '$id.yaml'));
  }

  /// ETag / Last-Modified cache for one profile's subscription URL.
  File profileHttpCacheFile(String id) {
    assertSafeProfileId(id);
    return File(p.join(profilesDir.path, '$id.http.json'));
  }

  Future<void> createAll() async {
    for (final directory in <Directory>[dataDir, profilesDir, workDir]) {
      if (!directory.existsSync()) await directory.create(recursive: true);
    }
  }
}
