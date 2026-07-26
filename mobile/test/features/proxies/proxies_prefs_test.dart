import 'package:aikobox_mobile/features/proxies/proxies_prefs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gives the notifier's `SharedPreferences` round trip a chance to land.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('enum wire names', () {
    test('round-trip, and an unknown value falls back to the default', () {
      for (final value in ProxiesViewType.values) {
        expect(ProxiesViewType.fromWire(value.wireName), value);
      }
      for (final value in ProxyCardDensity.values) {
        expect(ProxyCardDensity.fromWire(value.wireName), value);
      }
      for (final value in ProxiesLayout.values) {
        expect(ProxiesLayout.fromWire(value.wireName), value);
      }

      expect(ProxiesViewType.fromWire('nonsense'), ProxiesViewType.tab);
      expect(ProxyCardDensity.fromWire(null), ProxyCardDensity.shrink);
      expect(ProxiesLayout.fromWire(7), ProxiesLayout.standard);
    });

    test('the layout nudge is the FlClash one', () {
      expect(ProxiesLayout.loose.columnDelta, -1);
      expect(ProxiesLayout.standard.columnDelta, 0);
      expect(ProxiesLayout.tight.columnDelta, 1);
    });
  });

  group('loadProxiesPrefs', () {
    test('an empty store yields the defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await loadProxiesPrefs(), ProxiesPrefs.defaults);
    });

    test('reads everything back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kProxiesViewTypePrefKey: 'list',
        kProxiesDensityPrefKey: 'expand',
        kProxiesLayoutPrefKey: 'tight',
        kProxiesExpandedPrefKey: <String>['Proxy', 'Auto'],
        kProxiesActiveGroupPrefKey: 'Auto',
      });

      final prefs = await loadProxiesPrefs();
      expect(prefs.viewType, ProxiesViewType.list);
      expect(prefs.density, ProxyCardDensity.expand);
      expect(prefs.layout, ProxiesLayout.tight);
      expect(prefs.expandedGroups, <String>{'Proxy', 'Auto'});
      expect(prefs.activeGroup, 'Auto');
      expect(prefs.isExpanded('Proxy'), isTrue);
      expect(prefs.isExpanded('Other'), isFalse);
    });

    test(
      'a corrupt value degrades to the default for that field only',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          kProxiesViewTypePrefKey: 'sideways',
          kProxiesDensityPrefKey: 'expand',
        });
        final prefs = await loadProxiesPrefs();
        expect(prefs.viewType, ProxiesViewType.tab);
        expect(prefs.density, ProxyCardDensity.expand);
      },
    );
  });

  group('ProxiesPrefsNotifier', () {
    test('starts on the defaults, then hydrates from disk', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kProxiesViewTypePrefKey: 'list',
        kProxiesExpandedPrefKey: <String>['Proxy'],
      });

      final container = ProviderContainer.test();
      expect(container.read(proxiesPrefsProvider), ProxiesPrefs.defaults);

      await _drain();
      final prefs = container.read(proxiesPrefsProvider);
      expect(prefs.viewType, ProxiesViewType.list);
      expect(prefs.expandedGroups, <String>{'Proxy'});
    });

    test('every change is written straight back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer.test();
      final notifier = container.read(proxiesPrefsProvider.notifier);
      await _drain();

      await notifier.setViewType(ProxiesViewType.list);
      await notifier.setDensity(ProxyCardDensity.min);
      await notifier.setLayout(ProxiesLayout.loose);
      await notifier.setActiveGroup('Auto');
      await notifier.toggleGroup('Proxy');
      await notifier.settle();

      final store = await SharedPreferences.getInstance();
      expect(store.getString(kProxiesViewTypePrefKey), 'list');
      expect(store.getString(kProxiesDensityPrefKey), 'min');
      expect(store.getString(kProxiesLayoutPrefKey), 'loose');
      expect(store.getString(kProxiesActiveGroupPrefKey), 'Auto');
      expect(store.getStringList(kProxiesExpandedPrefKey), <String>['Proxy']);
    });

    test(
      'toggleGroup is a toggle, and expand/collapse all are wholesale',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final container = ProviderContainer.test();
        final notifier = container.read(proxiesPrefsProvider.notifier);
        await _drain();

        await notifier.toggleGroup('Proxy');
        expect(
          container.read(proxiesPrefsProvider).isExpanded('Proxy'),
          isTrue,
        );
        await notifier.toggleGroup('Proxy');
        expect(
          container.read(proxiesPrefsProvider).isExpanded('Proxy'),
          isFalse,
        );

        await notifier.expandAll(<String>['A', 'B', 'C']);
        expect(container.read(proxiesPrefsProvider).expandedGroups, <String>{
          'A',
          'B',
          'C',
        });

        await notifier.collapseAll();
        expect(container.read(proxiesPrefsProvider).expandedGroups, isEmpty);

        await notifier.settle();
        final store = await SharedPreferences.getInstance();
        expect(store.getStringList(kProxiesExpandedPrefKey), isEmpty);
      },
    );

    test('setting a value it already has is a no-op', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer.test();
      final notifier = container.read(proxiesPrefsProvider.notifier);
      await _drain();

      await notifier.setViewType(ProxiesViewType.tab);
      await notifier.settle();

      final store = await SharedPreferences.getInstance();
      expect(
        store.getString(kProxiesViewTypePrefKey),
        isNull,
        reason: 'nothing changed, so nothing should have been written',
      );
    });
  });

  group('ProxiesPrefs value semantics', () {
    test('equality covers the expanded set', () {
      const a = ProxiesPrefs(expandedGroups: <String>{'x', 'y'});
      const b = ProxiesPrefs(expandedGroups: <String>{'y', 'x'});
      const c = ProxiesPrefs(expandedGroups: <String>{'x'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith can clear the remembered tab', () {
      const prefs = ProxiesPrefs(activeGroup: 'Auto');
      expect(prefs.copyWith().activeGroup, 'Auto');
      expect(prefs.copyWith(clearActiveGroup: true).activeGroup, isNull);
    });
  });
}
