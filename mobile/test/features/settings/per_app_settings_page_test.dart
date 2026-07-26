import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/settings/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late Map<String, String> en;

  setUp(() {
    resetSettingsTestEnvironment();
    en = loadLocaleStrings();
  });

  AppConfig configOf(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(PerAppSettingsPage)),
    listen: false,
  ).read(appConfigProvider);

  Future<void> pumpPerApp(
    WidgetTester tester, {
    AppConfig config = AppConfig.defaults,
    CoreStatus status = CoreStatus.stopped,
  }) => pumpSettings(
    tester,
    const PerAppSettingsPage(),
    overrides: settingsOverrides(
      config: config,
      status: status,
      apps: sampleApps(),
    ),
    surface: const Size(420, 1000),
  );

  testWidgets('off mode hides the picker and explains itself', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(tester);

    expect(find.text(en['perApp.mode.offHint']!), findsOneWidget);
    expect(find.byKey(const Key('per-app-search')), findsNothing);
    expect(find.byKey(const Key('per-app-list')), findsNothing);
  });

  testWidgets('choosing a mode persists it and reveals the app list', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(tester);

    await tester.tap(
      find.widgetWithText(ChoiceChip, en['perApp.mode.allowlist']!),
    );
    await tester.pumpAndSettle();

    expect(configOf(tester).splitTunnelMode, SplitTunnelMode.allow);
    expect(find.text(en['perApp.mode.allowlistHint']!), findsOneWidget);
    expect(find.byKey(const Key('per-app-search')), findsOneWidget);
    expect(find.byKey(const Key('per-app-list')), findsOneWidget);
  });

  testWidgets('user apps are listed, system apps and AikoBox are not', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.deny,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('per-app-com.example.browser')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('per-app-com.example.chat')),
      findsOneWidget,
    );
    // System apps are behind the toggle...
    expect(
      find.byKey(const ValueKey<String>('per-app-com.android.settings')),
      findsNothing,
    );
    // ...and AikoBox can never be excluded from its own tunnel.
    expect(
      find.byKey(const ValueKey<String>('per-app-$kTestPackageName')),
      findsNothing,
    );
    expect(find.text(en['perApp.selfLocked']!), findsOneWidget);
  });

  testWidgets('the system-app toggle reveals system packages', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.deny,
      ),
    );

    await tester.tap(find.byKey(const Key('per-app-system')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('per-app-com.android.settings')),
      findsOneWidget,
    );
    expect(find.textContaining(en['perApp.systemLabel']!), findsOneWidget);
  });

  testWidgets('ticking an app writes it to splitTunnelPackages', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.allow,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('per-app-com.example.chat')),
    );
    await tester.pumpAndSettle();

    expect(configOf(tester).splitTunnelPackages, <String>['com.example.chat']);
    // Allow mode feeds the include list and leaves the exclude list empty.
    expect(configOf(tester).includePackages, <String>['com.example.chat']);
    expect(configOf(tester).excludePackages, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('per-app-com.example.chat')),
    );
    await tester.pumpAndSettle();
    expect(configOf(tester).splitTunnelPackages, isEmpty);
  });

  testWidgets('deny mode feeds the exclude list instead', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.deny,
        splitTunnelPackages: const <String>['com.example.browser'],
      ),
    );

    expect(configOf(tester).excludePackages, <String>['com.example.browser']);
    expect(configOf(tester).includePackages, isEmpty);
  });

  testWidgets('search narrows the list', (WidgetTester tester) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.allow,
      ),
    );

    await tester.enterText(find.byKey(const Key('per-app-search')), 'chat');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('per-app-com.example.chat')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('per-app-com.example.browser')),
      findsNothing,
    );
  });

  testWidgets('select all only takes the rows the filter is showing', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.allow,
      ),
    );

    await tester.enterText(find.byKey(const Key('per-app-search')), 'browser');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('per-app-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['common.selectAll']!).last);
    await tester.pumpAndSettle();

    expect(configOf(tester).splitTunnelPackages, <String>[
      'com.example.browser',
    ]);
  });

  testWidgets('a tick that could not be written is put back', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const PerAppSettingsPage(),
      overrides: settingsOverrides(
        config: AppConfig.defaults.copyWith(
          splitTunnelMode: SplitTunnelMode.allow,
        ),
        apps: sampleApps(),
        failWrites: true,
      ),
      surface: const Size(420, 1000),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('per-app-com.example.chat')),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey<String>('per-app-com.example.chat')),
          )
          .value,
      isFalse,
    );
    expect(
      find.text(en['common.error.updateAppConfigFailed']!),
      findsOneWidget,
    );
  });

  testWidgets('a running core gets the restart caveat', (
    WidgetTester tester,
  ) async {
    await pumpPerApp(
      tester,
      config: AppConfig.defaults.copyWith(
        splitTunnelMode: SplitTunnelMode.allow,
      ),
      status: const CoreStatus(state: CoreState.running, version: 'test'),
    );

    expect(find.text(en['perApp.restartHint']!), findsOneWidget);
  });
}
