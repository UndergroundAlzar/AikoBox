import 'dart:convert';
import 'dart:typed_data';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/settings/settings.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late Map<String, String> en;

  setUp(() {
    resetSettingsTestEnvironment();
    en = loadLocaleStrings();
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(BackupPage)),
        listen: false,
      );

  testWidgets('export hands a decodable document to the file writer', (
    WidgetTester tester,
  ) async {
    String? writtenName;
    String? writtenBody;

    final AppConfig config = AppConfig.defaults.copyWith(
      logLevel: LogLevel.debug,
      splitTunnelMode: SplitTunnelMode.allow,
      splitTunnelPackages: const <String>['com.example.chat'],
    );

    await pumpSettings(
      tester,
      const BackupPage(),
      overrides: settingsOverrides(
        config: config,
        extra: <Override>[
          backupWriterProvider.overrideWithValue((
            String name,
            Uint8List bytes,
          ) async {
            writtenName = name;
            writtenBody = utf8.decode(bytes);
            return '/storage/emulated/0/Download/$name';
          }),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('backup-export')));
    await tester.pumpAndSettle();

    expect(writtenName, startsWith('aikobox-config-'));
    expect(writtenName, endsWith('.json'));

    final AikoBackup restored = decodeAikoBackup(writtenBody!);
    expect(restored.appConfig, config);
    expect(restored.appVersion, '0.1.0+1');
    expect(
      find.text(en['localBackup.notification.exportSuccess.title']!),
      findsOneWidget,
    );
  });

  testWidgets('a cancelled export says nothing', (WidgetTester tester) async {
    await pumpSettings(
      tester,
      const BackupPage(),
      overrides: settingsOverrides(
        extra: <Override>[
          backupWriterProvider.overrideWithValue(
            (String name, Uint8List bytes) async => null,
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('backup-export')));
    await tester.pumpAndSettle();

    expect(
      find.text(en['localBackup.notification.exportSuccess.title']!),
      findsNothing,
    );
  });

  testWidgets('import confirms, then applies settings, theme and language', (
    WidgetTester tester,
  ) async {
    final AppConfig incoming = AppConfig.defaults.copyWith(
      appTheme: AppThemeMode.dark,
      seedColor: kAikoSeedAzure.color.toARGB32(),
      useDynamicColor: false,
      language: 'zh-CN',
      maxLogLines: 321,
    );
    final String document = encodeAikoBackup(
      incoming,
      exportedAt: DateTime.utc(2026, 7, 26),
    );

    await pumpSettings(
      tester,
      const BackupPage(),
      overrides: settingsOverrides(
        extra: <Override>[
          backupReaderProvider.overrideWithValue(() async => document),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import')));
    await tester.pumpAndSettle();

    // Nothing is applied until the sheet is confirmed.
    expect(find.text(en['localBackup.import.confirm.title']!), findsOneWidget);
    final ProviderContainer container = containerOf(tester);
    expect(container.read(appConfigProvider).maxLogLines, 1000);

    await tester.tap(find.text(en['common.confirm']!));
    await tester.pumpAndSettle();

    expect(container.read(appConfigProvider).maxLogLines, 321);
    expect(container.read(themeControllerProvider).themeMode, ThemeMode.dark);
    expect(container.read(themeControllerProvider).seedColorId, 'azure');
    expect(container.read(themeControllerProvider).useDynamicColor, isFalse);
    expect(container.read(localeSettingProvider), 'zh-CN');
  });

  testWidgets('cancelling the import leaves everything alone', (
    WidgetTester tester,
  ) async {
    final String document = encodeAikoBackup(
      AppConfig.defaults.copyWith(maxLogLines: 321),
      exportedAt: DateTime.utc(2026, 7, 26),
    );

    await pumpSettings(
      tester,
      const BackupPage(),
      overrides: settingsOverrides(
        extra: <Override>[
          backupReaderProvider.overrideWithValue(() async => document),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['common.cancel']!));
    await tester.pumpAndSettle();

    expect(containerOf(tester).read(appConfigProvider).maxLogLines, 1000);
  });

  testWidgets('a file that is not a backup is reported, not applied', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const BackupPage(),
      overrides: settingsOverrides(
        extra: <Override>[
          backupReaderProvider.overrideWithValue(
            () async => '{"format":"something-else","version":1}',
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('backup-import')));
    await tester.pumpAndSettle();

    expect(find.text(en['localBackup.import.confirm.title']!), findsNothing);
    expect(
      find.textContaining(BackupFormatException.codeWrongFormat),
      findsOneWidget,
    );
  });
}
