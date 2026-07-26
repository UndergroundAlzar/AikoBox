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
    tester.element(find.byType(DashboardCardsPage)),
    listen: false,
  ).read(appConfigProvider);

  group('normaliseCardOrder', () {
    test('fills in cards a stale config never heard of', () {
      expect(normaliseCardOrder(<String>['log', 'network']), <String>[
        'log',
        'network',
        ...kDefaultCardOrder.where((String k) => k != 'log' && k != 'network'),
      ]);
    });

    test('drops unknown keys and duplicates', () {
      final List<String> result = normaliseCardOrder(<String>[
        'network',
        'network',
        'sysproxy',
        'log',
      ]);
      expect(result.where((String k) => k == 'network').length, 1);
      expect(result, isNot(contains('sysproxy')));
      expect(result.toSet(), kDefaultCardOrder.toSet());
    });

    test('an empty order still produces the full default set', () {
      expect(normaliseCardOrder(const <String>[]), kDefaultCardOrder);
    });
  });

  testWidgets('lists every card with its current size', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const DashboardCardsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1800),
    );

    for (final String key in kDefaultCardOrder) {
      expect(
        find.byKey(ValueKey<String>('card-$key')),
        findsOneWidget,
        reason: key,
      );
    }
    // network defaults to a full-width card, proxy to a half-width one.
    expect(find.text(en['sider.size.large']!), findsWidgets);
    expect(find.text(en['sider.size.small']!), findsWidgets);
  });

  testWidgets('changing a card size writes cardStatus', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const DashboardCardsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1800),
    );

    await tester.tap(find.byKey(const ValueKey<String>('card-log')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('aiko-option-CardStatus.hidden')),
    );
    await tester.pumpAndSettle();

    expect(configOf(tester).statusOfCard('log'), CardStatus.hidden);
    expect(
      configOf(tester).toJson()['cardStatus'],
      containsPair('log', 'hidden'),
    );
    // Untouched cards keep their defaults.
    expect(configOf(tester).statusOfCard('network'), CardStatus.colSpan2);
  });

  testWidgets('reset restores the default order and sizes', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const DashboardCardsPage(),
      overrides: settingsOverrides(
        config: AppConfig.defaults.copyWith(
          cardOrder: const <String>['log', 'dns'],
          cardStatus: const <String, CardStatus>{'log': CardStatus.hidden},
        ),
      ),
      surface: const Size(420, 1800),
    );

    await tester.tap(find.byKey(const Key('cards-reset')));
    await tester.pumpAndSettle();

    expect(configOf(tester).cardOrder, kDefaultCardOrder);
    expect(configOf(tester).statusOfCard('log'), CardStatus.colSpan1);
  });
}
