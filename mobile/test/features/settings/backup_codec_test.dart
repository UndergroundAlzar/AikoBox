import 'dart:convert';

import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/settings/backup_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final AppConfig sample = AppConfig.defaults.copyWith(
    appTheme: AppThemeMode.dark,
    seedColor: 0xFF2F9E68,
    useDynamicColor: false,
    language: 'zh-CN',
    delayTestUrl: 'https://example.test/generate_204',
    delayTestTimeout: 7000,
    logLevel: LogLevel.debug,
    maxLogLines: 4000,
    splitTunnelMode: SplitTunnelMode.deny,
    splitTunnelPackages: const <String>['com.example.a', 'com.example.b'],
    cardOrder: const <String>['log', 'network'],
  );

  group('encode / decode', () {
    test('round-trips every persisted field', () {
      final DateTime at = DateTime.utc(2026, 7, 26, 18, 30);
      final AikoBackup restored = decodeAikoBackup(
        encodeAikoBackup(sample, exportedAt: at, appVersion: '0.1.0+1'),
      );

      expect(restored.appConfig, sample);
      expect(restored.appVersion, '0.1.0+1');
      expect(restored.exportedAt.toUtc(), at);
    });

    test('writes a self-describing, human-readable document', () {
      final String raw = encodeAikoBackup(
        sample,
        exportedAt: DateTime.utc(2026, 1, 1),
      );
      expect(raw, contains('\n  "format": "$kBackupFormat"'));

      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['version'], kBackupFormatVersion);
      expect(decoded['appConfig'], isA<Map<String, dynamic>>());
      // Nothing but settings: no profiles, no subscription URLs, no tokens.
      expect(
        decoded.keys,
        unorderedEquals(<String>[
          'format',
          'version',
          'exportedAt',
          'appConfig',
        ]),
      );
    });
  });

  group('rejection', () {
    test('refuses text that is not JSON', () {
      expect(
        () => decodeAikoBackup('not json at all'),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.code,
            'code',
            BackupFormatException.codeNotJson,
          ),
        ),
      );
    });

    test('refuses a JSON array', () {
      expect(
        () => decodeAikoBackup('[1, 2, 3]'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('refuses a file from another app', () {
      final String raw = jsonEncode(<String, dynamic>{
        'format': 'some-other-tool',
        'version': 1,
        'appConfig': <String, dynamic>{'appTheme': 'dark'},
      });
      expect(
        () => decodeAikoBackup(raw),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.code,
            'code',
            BackupFormatException.codeWrongFormat,
          ),
        ),
      );
    });

    test('refuses a backup written by a newer build', () {
      final String raw = jsonEncode(<String, dynamic>{
        'format': kBackupFormat,
        'version': kBackupFormatVersion + 1,
        'appConfig': <String, dynamic>{'appTheme': 'dark'},
      });
      expect(
        () => decodeAikoBackup(raw),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.code,
            'code',
            BackupFormatException.codeTooNew,
          ),
        ),
      );
    });

    test('refuses a payload with no key this build recognises', () {
      // AppConfig.fromJson coerces anything, so without this guard an object of
      // unrelated keys would decode to the defaults and silently wipe settings.
      final String raw = jsonEncode(<String, dynamic>{
        'format': kBackupFormat,
        'version': 1,
        'appConfig': <String, dynamic>{'totally': 'unrelated'},
      });
      expect(
        () => decodeAikoBackup(raw),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.code,
            'code',
            BackupFormatException.codeNoPayload,
          ),
        ),
      );
    });

    test('refuses an empty payload', () {
      final String raw = jsonEncode(<String, dynamic>{
        'format': kBackupFormat,
        'version': 1,
        'appConfig': <String, dynamic>{},
      });
      expect(
        () => decodeAikoBackup(raw),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('tolerance', () {
    test('a partial payload keeps the defaults for what it omits', () {
      final String raw = jsonEncode(<String, dynamic>{
        'format': kBackupFormat,
        'version': 1,
        'appConfig': <String, dynamic>{'maxLogLines': 250},
      });
      final AikoBackup restored = decodeAikoBackup(raw);
      expect(restored.appConfig.maxLogLines, 250);
      expect(restored.appConfig.delayTestUrl, AppConfig.defaults.delayTestUrl);
    });

    test('a missing exportedAt does not throw', () {
      final String raw = jsonEncode(<String, dynamic>{
        'format': kBackupFormat,
        'version': 1,
        'appConfig': <String, dynamic>{'ipv6': true},
      });
      expect(decodeAikoBackup(raw).appConfig.ipv6, isTrue);
    });
  });

  test('the default file name is timestamped and JSON', () {
    expect(
      defaultBackupFileName(DateTime(2026, 7, 26, 18, 5)),
      'aikobox-config-20260726-1805.json',
    );
    expect(
      defaultBackupFileName(DateTime(2026, 11, 3, 9, 40)),
      'aikobox-config-20261103-0940.json',
    );
  });
}
