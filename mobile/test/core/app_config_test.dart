import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/app_config.dart';
import 'package:aikobox_mobile/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dataDir;
  late File file;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('aikobox-app-config-');
    file = File(p.join(dataDir.path, 'config.json'));
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  group('AppConfig', () {
    test('round-trips through JSON', () {
      const original = AppConfig(
        appTheme: AppThemeMode.dark,
        seedColor: 0xFFDC2626,
        language: 'zh-CN',
        splitTunnelMode: SplitTunnelMode.deny,
        splitTunnelPackages: <String>['com.example.a', 'com.example.b'],
        logLevel: LogLevel.debug,
      );

      final restored = AppConfig.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored, original);
      expect(restored.hashCode, original.hashCode);
      expect(restored.splitTunnelPackages, original.splitTunnelPackages);
    });

    test('unknown and missing keys fall back to defaults', () {
      final config = AppConfig.fromJson(<String, dynamic>{
        'appTheme': 'chartreuse',
        'proxyDisplayOrder': 'nonsense',
        'somethingFromTheFuture': true,
      });

      expect(config.appTheme, AppThemeMode.system);
      expect(config.proxyDisplayOrder, ProxySortOrder.byDefault);
      expect(config.delayTestTimeout, AppConfig.defaults.delayTestTimeout);
    });

    test(
      'the split-tunnel list feeds exactly one of the two package lists',
      () {
        const packages = <String>['com.example.a'];
        const off = AppConfig(splitTunnelPackages: packages);
        expect(off.includePackages, isEmpty);
        expect(off.excludePackages, isEmpty);

        const allow = AppConfig(
          splitTunnelMode: SplitTunnelMode.allow,
          splitTunnelPackages: packages,
        );
        expect(allow.includePackages, packages);
        expect(allow.excludePackages, isEmpty);

        const deny = AppConfig(
          splitTunnelMode: SplitTunnelMode.deny,
          splitTunnelPackages: packages,
        );
        expect(deny.includePackages, isEmpty);
        expect(deny.excludePackages, packages);
      },
    );

    test('card status merges saved values over the defaults', () {
      final config = AppConfig.fromJson(<String, dynamic>{
        'cardStatus': <String, dynamic>{'log': 'hidden'},
      });

      expect(config.statusOfCard('log'), CardStatus.hidden);
      expect(config.statusOfCard('network'), CardStatus.colSpan2);
      expect(config.statusOfCard('unknown-card'), CardStatus.colSpan1);
    });
  });

  group('AppConfigStore', () {
    test('returns defaults when nothing has been written yet', () async {
      final store = AppConfigStore(file);
      expect(await store.read(), AppConfig.defaults);
      expect(
        file.existsSync(),
        isFalse,
        reason: 'reading must not create the file',
      );
    });

    test('persists an update atomically and leaves no temp files', () async {
      final store = AppConfigStore(file);
      await store.update((current) => current.copyWith(seedColor: 0xFF00FF00));

      expect(jsonDecode(file.readAsStringSync())['seedColor'], 0xFF00FF00);
      final leftovers = dataDir.listSync().whereType<File>().where(
        (f) => p.basename(f.path).endsWith('.tmp'),
      );
      expect(leftovers, isEmpty);

      // A fresh store sees what the previous one wrote.
      expect((await AppConfigStore(file).read()).seedColor, 0xFF00FF00);
    });

    test(
      'a corrupt settings file falls back to defaults rather than throwing',
      () async {
        file.writeAsStringSync('{ this is not json');
        expect(await AppConfigStore(file).read(), AppConfig.defaults);
      },
    );

    test(
      'a settings file that is not an object falls back to defaults',
      () async {
        file.writeAsStringSync('[1,2,3]');
        expect(await AppConfigStore(file).read(), AppConfig.defaults);
      },
    );

    test('concurrent updates are serialised, so none is lost', () async {
      final store = AppConfigStore(file);
      await Future.wait(<Future<AppConfig>>[
        store.update((c) => c.copyWith(seedColor: 1)),
        store.update((c) => c.copyWith(maxLogLines: 250)),
        store.update((c) => c.copyWith(ipv6: true)),
      ]);

      final persisted = await AppConfigStore(file).read();
      expect(persisted.seedColor, 1);
      expect(persisted.maxLogLines, 250);
      expect(persisted.ipv6, isTrue);
    });

    test('flush resolves once every queued write has landed', () async {
      final store = AppConfigStore(file);
      unawaitedUpdate(store);
      await store.flush();
      expect(file.existsSync(), isTrue);
    });
  });
}

/// Kicks off a write without awaiting it, so `flush` has something to wait on.
void unawaitedUpdate(AppConfigStore store) {
  store.update((current) => current.copyWith(silentStart: true)).ignore();
}
