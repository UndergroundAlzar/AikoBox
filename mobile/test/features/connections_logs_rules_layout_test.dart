/// Cross-cutting checks on the three pages this area owns: they have to lay out
/// on a narrow phone, in dark mode, and under `fa-IR`'s right-to-left
/// direction with its longer strings.
///
/// A `RenderFlex` overflow throws in a widget test, so simply pumping each page
/// in each configuration is the assertion. The explicit `Directionality` check
/// is there because an app bar that hard-codes `EdgeInsets.only(left:)` looks
/// fine in English and wrong in Persian, and nothing else would catch it.
library;

import 'dart:async';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/connections/connections_page.dart';
import 'package:aikobox_mobile/features/logs/logs_page.dart';
import 'package:aikobox_mobile/features/rules/rules_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late StreamController<ConnectionsSnapshot> socket;

  setUp(() {
    socket = StreamController<ConnectionsSnapshot>.broadcast();
    addTearDown(socket.close);
  });

  ProviderContainer makeContainer() => ProviderContainer.test(
    overrides: [
      coreStatusProvider.overrideWith(
        () => FakeCoreStatusNotifier(runningStatus),
      ),
      connectionsSnapshotProvider.overrideWith((Ref ref) => socket.stream),
      appConfigProvider.overrideWith(
        () => FakeAppConfigNotifier(AppConfig.defaults),
      ),
      coreControllerProvider.overrideWithValue(RecordingCoreController()),
      logsProvider.overrideWith(
        () => FakeLogsNotifier(<LogLine>[
          LogLine(
            level: 'error',
            payload: 'dial tcp 93.184.216.34:443: connection refused',
            time: DateTime.utc(2026, 7, 26, 12),
          ),
        ]),
      ),
      rulesProvider.overrideWith(
        (Ref ref) async => const <RuleItem>[
          RuleItem(
            type: 'DomainSuffix',
            payload: 'a.very.long.example.domain.name.test',
            proxy: 'PROXY',
          ),
        ],
      ),
      ruleProvidersProvider.overrideWith(
        (Ref ref) async => <String, ProviderInfo>{
          'ads': ProviderInfo(
            name: 'ads',
            type: 'Rule',
            vehicleType: 'HTTP',
            behavior: 'domain',
            format: 'yaml',
            ruleCount: 4211,
            updatedAt: DateTime(2026, 7, 26, 9, 30),
          ),
        },
      ),
      clashApiProvider.overrideWith((Ref ref) async {
        throw StateError('no core in tests');
      }),
    ],
  );

  Future<void> feed(WidgetTester tester) async {
    socket.add(
      ConnectionsSnapshot(
        connections: <ConnectionInfo>[
          makeConnection(
            id: 'a',
            host: 'a.very.long.example.domain.name.test:443',
            process: 'com.example.some.rather.long.package',
            chains: const <String>['HK-01-Premium', 'PROXY'],
            upload: 987654321,
            download: 123456789,
            uploadSpeed: 4096,
            downloadSpeed: 8192,
          ),
        ],
        uploadTotal: 987654321,
        downloadTotal: 123456789,
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final ({String name, Brightness brightness, Locale locale}) variant
      in <({String name, Brightness brightness, Locale locale})>[
        (
          name: 'dark en-US',
          brightness: Brightness.dark,
          locale: const Locale('en', 'US'),
        ),
        (
          name: 'light zh-CN',
          brightness: Brightness.light,
          locale: const Locale('zh', 'CN'),
        ),
        (
          name: 'dark fa-IR',
          brightness: Brightness.dark,
          locale: const Locale('fa', 'IR'),
        ),
      ]) {
    testWidgets('connections lays out in ${variant.name}', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        const ConnectionsPage(),
        container: makeContainer(),
        brightness: variant.brightness,
        locale: variant.locale,
      );
      await feed(tester);
      expect(find.byType(ConnectionsPage), findsOneWidget);
    });

    testWidgets('logs lays out in ${variant.name}', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        const LogsPage(),
        container: makeContainer(),
        brightness: variant.brightness,
        locale: variant.locale,
      );
      expect(find.byType(LogsPage), findsOneWidget);
    });

    testWidgets('rules lays out in ${variant.name}', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        const RulesPage(),
        container: makeContainer(),
        brightness: variant.brightness,
        locale: variant.locale,
      );
      expect(find.byType(RulesPage), findsOneWidget);
    });
  }

  testWidgets('fa-IR renders the pages right to left', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const RulesPage(),
      container: makeContainer(),
      locale: const Locale('fa', 'IR'),
    );
    expect(
      Directionality.of(tester.element(find.byType(RulesPage))),
      TextDirection.rtl,
    );
  });

  testWidgets('a very narrow phone still lays the connections page out', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(),
      surface: const Size(320, 640),
    );
    await feed(tester);
    expect(find.byType(ConnectionsPage), findsOneWidget);
  });

  testWidgets('a very narrow phone still lays the logs page out', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(),
      surface: const Size(320, 640),
    );
    expect(find.byType(LogsPage), findsOneWidget);
  });

  testWidgets('a very narrow phone still lays the rules page out', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const RulesPage(),
      container: makeContainer(),
      surface: const Size(320, 640),
    );
    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
    expect(find.byType(RulesPage), findsOneWidget);
  });
}
