/// The on-disk shape of a local settings backup.
///
/// Deliberately narrow: it carries `config.json` and nothing else. Profiles are
/// **not** included, because a subscription URL commonly embeds a token and
/// writing that into a user-chosen file — one that a backup app, a cloud sync
/// client or a chat share sheet can then pick up — is exactly the kind of
/// credential leak N7 exists to prevent.
///
/// Pure functions only: no Flutter, no plugins, no IO. The page that calls them
/// owns the file dialogs.
library;

import 'dart:convert';

import '../../core/models.dart';

/// Discriminator written into every backup so a file from another app (or from
/// the desktop client, whose config shape differs) is rejected instead of
/// half-applied.
const String kBackupFormat = 'aikobox-android-config';

/// Bumped when the payload shape changes incompatibly. A backup from a *newer*
/// version is refused rather than guessed at.
const int kBackupFormatVersion = 1;

/// A decoded backup file.
class AikoBackup {
  const AikoBackup({
    required this.appConfig,
    required this.exportedAt,
    this.appVersion = '',
  });

  final AppConfig appConfig;
  final DateTime exportedAt;

  /// Version of the app that produced the file. Informational only.
  final String appVersion;
}

/// Raised when a file is not an AikoBox backup, or is one this build cannot
/// read. The message is a stable code the caller maps to an l10n string; it
/// never contains file contents.
class BackupFormatException implements Exception {
  const BackupFormatException(this.code);

  /// Not JSON, or not a JSON object.
  static const String codeNotJson = 'E_BACKUP_NOT_JSON';

  /// Missing or wrong `format` discriminator.
  static const String codeWrongFormat = 'E_BACKUP_WRONG_FORMAT';

  /// `version` is newer than [kBackupFormatVersion].
  static const String codeTooNew = 'E_BACKUP_TOO_NEW';

  /// `appConfig` is absent or not a recognisable settings object.
  static const String codeNoPayload = 'E_BACKUP_NO_PAYLOAD';

  final String code;

  @override
  String toString() => 'BackupFormatException($code)';
}

/// Serialises [config] as a backup document, pretty-printed so a user who opens
/// the file in a text editor can read it.
String encodeAikoBackup(
  AppConfig config, {
  required DateTime exportedAt,
  String appVersion = '',
}) {
  final Map<String, dynamic> document = <String, dynamic>{
    'format': kBackupFormat,
    'version': kBackupFormatVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    if (appVersion.isNotEmpty) 'appVersion': appVersion,
    'appConfig': config.toJson(),
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

/// Parses a backup document. Throws [BackupFormatException] on anything that is
/// not one.
AikoBackup decodeAikoBackup(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw const BackupFormatException(BackupFormatException.codeNotJson);
  }
  if (decoded is! Map) {
    throw const BackupFormatException(BackupFormatException.codeNotJson);
  }

  if (decoded['format'] != kBackupFormat) {
    throw const BackupFormatException(BackupFormatException.codeWrongFormat);
  }

  final Object? version = decoded['version'];
  final int parsedVersion = version is int
      ? version
      : int.tryParse('$version') ?? -1;
  if (parsedVersion < 1) {
    throw const BackupFormatException(BackupFormatException.codeWrongFormat);
  }
  if (parsedVersion > kBackupFormatVersion) {
    throw const BackupFormatException(BackupFormatException.codeTooNew);
  }

  final Object? payload = decoded['appConfig'];
  if (payload is! Map || payload.isEmpty) {
    throw const BackupFormatException(BackupFormatException.codeNoPayload);
  }
  final Map<String, dynamic> settings = <String, dynamic>{
    for (final MapEntry<Object?, Object?> entry in payload.entries)
      '${entry.key}': entry.value,
  };
  // `AppConfig.fromJson` coerces anything, so an object full of unrelated keys
  // would silently decode to the defaults and wipe the user's settings. Require
  // at least one key this build actually knows.
  final Set<String> known = AppConfig.defaults.toJson().keys.toSet();
  if (!settings.keys.any(known.contains)) {
    throw const BackupFormatException(BackupFormatException.codeNoPayload);
  }

  return AikoBackup(
    appConfig: AppConfig.fromJson(settings),
    exportedAt:
        DateTime.tryParse('${decoded['exportedAt']}')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    appVersion: decoded['appVersion'] is String
        ? decoded['appVersion'] as String
        : '',
  );
}

/// `aikobox-config-20260726-1830.json`.
///
/// Timestamped rather than fixed so successive exports do not overwrite one
/// another in the user's Downloads folder.
String defaultBackupFileName(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'aikobox-config-${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}.json';
}
