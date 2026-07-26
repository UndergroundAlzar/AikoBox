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

  AppConfig configOf(WidgetTester tester, Type page) =>
      ProviderScope.containerOf(
        tester.element(find.byType(page)),
        listen: false,
      ).read(appConfigProvider);

  Future<void> pumpApp(
    WidgetTester tester, {
    AppConfig config = AppConfig.defaults,
  }) => pumpSettings(
    tester,
    const AppSettingsPage(),
    overrides: settingsOverrides(config: config),
    surface: const Size(420, 1400),
  );

  testWidgets('proxy display mode round-trips through the picker', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    expect(find.text(en['proxies.mode.simple']!), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-proxy-display-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('aiko-option-full')));
    await tester.pumpAndSettle();

    expect(configOf(tester, AppSettingsPage).proxyDisplayMode, 'full');
    expect(find.text(en['proxies.mode.full']!), findsOneWidget);
  });

  testWidgets('proxy sort order persists as the desktop enum value', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('app-proxy-order')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('aiko-option-ProxySortOrder.byDelay')),
    );
    await tester.pumpAndSettle();

    final AppConfig config = configOf(tester, AppSettingsPage);
    expect(config.proxyDisplayOrder, ProxySortOrder.byDelay);
    expect(config.toJson()['proxyDisplayOrder'], 'delay');
  });

  testWidgets('proxy columns offer auto plus one to four', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('app-proxy-columns')));
    await tester.pumpAndSettle();
    for (final String value in kProxyColumnValues) {
      expect(
        find.byKey(ValueKey<String>('aiko-option-$value')),
        findsOneWidget,
        reason: value,
      );
    }

    await tester.tap(find.byKey(const ValueKey<String>('aiko-option-3')));
    await tester.pumpAndSettle();
    expect(configOf(tester, AppSettingsPage).proxyCols, '3');
  });

  testWidgets('hide-unavailable persists', (WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('app-hide-unavailable')));
    await tester.pumpAndSettle();
    expect(configOf(tester, AppSettingsPage).hideUnavailableProxies, isTrue);
  });

  testWidgets('the connection direction button flips asc/desc', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    expect(configOf(tester, AppSettingsPage).connectionDirection, 'desc');

    await tester.tap(find.byKey(const Key('app-connection-direction')));
    await tester.pumpAndSettle();
    expect(configOf(tester, AppSettingsPage).connectionDirection, 'asc');

    await tester.tap(find.byKey(const Key('app-connection-direction')));
    await tester.pumpAndSettle();
    expect(configOf(tester, AppSettingsPage).connectionDirection, 'desc');
  });

  testWidgets('subscription timeout is edited in seconds, stored in millis', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('30 ${en['common.seconds']!}'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-subscription-timeout')));
    await tester.pumpAndSettle();

    // Below the desktop's 30 s floor: the sheet will not commit it.
    await tester.enterText(find.byKey(const Key('aiko-text-sheet-field')), '5');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('aiko-text-sheet-save')))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('aiko-text-sheet-field')), '90');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiko-text-sheet-save')));
    await tester.pumpAndSettle();

    expect(configOf(tester, AppSettingsPage).subscriptionTimeout, 90000);
  });

  testWidgets('the dashboard-cards row opens the layout editor', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('app-dashboard-cards')));
    await tester.pumpAndSettle();

    expect(find.byType(DashboardCardsPage), findsOneWidget);
  });
}
