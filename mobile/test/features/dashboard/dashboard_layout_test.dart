import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDashboardCardOrder', () {
    test('an empty saved order yields the registry order', () {
      expect(
        resolveDashboardCardOrder(const <String>[]),
        kDashboardCards.map((DashboardCardSpec s) => s.key).toList(),
      );
    });

    test('the desktop default order round-trips, with latency appended', () {
      final List<String> resolved = resolveDashboardCardOrder(
        kDefaultCardOrder,
      );
      expect(resolved.take(kDefaultCardOrder.length), kDefaultCardOrder);
      expect(resolved.last, kLatencyCardKey);
      expect(resolved.length, kDashboardCards.length);
    });

    test('unknown keys are dropped and duplicates collapsed', () {
      final List<String> resolved = resolveDashboardCardOrder(<String>[
        'sysproxy', // desktop-only, has no Android card
        'log',
        'log',
        'tun',
      ]);
      expect(resolved.first, 'log');
      expect(resolved.where((String k) => k == 'log').length, 1);
      expect(resolved, isNot(contains('sysproxy')));
      expect(resolved, isNot(contains('tun')));
    });

    test('every registry key survives exactly once, whatever the input', () {
      for (final List<String> saved in <List<String>>[
        const <String>[],
        const <String>['bogus'],
        kDefaultCardOrder,
        kDashboardCards
            .map((DashboardCardSpec s) => s.key)
            .toList()
            .reversed
            .toList(),
      ]) {
        final List<String> resolved = resolveDashboardCardOrder(saved);
        expect(resolved.toSet().length, resolved.length);
        expect(
          resolved.toSet(),
          kDashboardCards.map((DashboardCardSpec s) => s.key).toSet(),
        );
      }
    });
  });

  group('registry', () {
    test('keys are unique and every card has an l10n key', () {
      final Set<String> keys = <String>{};
      for (final DashboardCardSpec spec in kDashboardCards) {
        expect(keys.add(spec.key), isTrue, reason: 'duplicate ${spec.key}');
        expect(spec.labelKey, isNotEmpty);
        expect(spec.labelKey, contains('.'));
      }
    });

    test('every desktop sider key that survived the port has a card', () {
      for (final String key in kDefaultCardOrder) {
        expect(
          dashboardCardSpec(key),
          isNotNull,
          reason: '$key is in kDefaultCardOrder but has no dashboard card',
        );
      }
    });

    test('defaults mirror the core layer where the keys overlap', () {
      final Map<String, CardStatus> defaults = defaultDashboardCardStatus();
      const AppConfig config = AppConfig.defaults;
      for (final String key in kDefaultCardOrder) {
        expect(defaults[key], config.statusOfCard(key), reason: key);
      }
      expect(defaults[kLatencyCardKey], CardStatus.colSpan1);
    });
  });

  group('buildDashboardGridItems', () {
    test('hidden cards are left out and spans follow CardStatus', () {
      final AppConfig config = AppConfig.defaults.copyWith(
        cardStatus: <String, CardStatus>{
          ...defaultDashboardCardStatus(),
          'log': CardStatus.hidden,
          'proxy': CardStatus.colSpan2,
        },
      );
      final List<String> order = resolveDashboardCardOrder(config.cardOrder);
      final List<StaggeredGridItem> items = buildDashboardGridItems(
        order: order,
        config: config,
      );

      expect(items.length, kDashboardCards.length - 1);
      final int proxyIndex = order
          .where((String key) => config.statusOfCard(key).isVisible)
          .toList()
          .indexOf('proxy');
      expect(items[proxyIndex].columnSpan, 2);
    });

    test('hiding everything produces an empty grid rather than a crash', () {
      final AppConfig config = AppConfig.defaults.copyWith(
        cardStatus: <String, CardStatus>{
          for (final DashboardCardSpec spec in kDashboardCards)
            spec.key: CardStatus.hidden,
        },
      );
      expect(
        buildDashboardGridItems(
          order: resolveDashboardCardOrder(config.cardOrder),
          config: config,
        ),
        isEmpty,
      );
    });

    test('the grid honours the persisted order, not the registry order', () {
      final List<String> reversed = resolveDashboardCardOrder(
        const <String>[],
      ).reversed.toList();
      final AppConfig config = AppConfig.defaults.copyWith(
        cardOrder: reversed,
        cardStatus: defaultDashboardCardStatus(),
      );
      final List<StaggeredGridItem> items = buildDashboardGridItems(
        order: resolveDashboardCardOrder(config.cardOrder),
        config: config,
      );
      expect(items.length, kDashboardCards.length);
      // The registry's first card is now last.
      expect(
        (items.last.child.key as ValueKey<String>).value,
        'dashboard-card-${kDashboardCards.first.key}',
      );
    });
  });
}
