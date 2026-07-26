import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/proxies/proxies_page.dart';
import 'package:aikobox_mobile/features/proxies/proxy_card.dart';
import 'package:aikobox_mobile/features/proxies/proxy_group_header.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'harness.dart';

class _FakeCoreStatus extends CoreStatusNotifier {
  _FakeCoreStatus(this.value);

  final CoreStatus value;

  @override
  CoreStatus build() => value;
}

class _FakeOutboundMode extends OutboundModeNotifier {
  _FakeOutboundMode(this.value);

  final OutboundMode value;

  @override
  Future<OutboundMode> build() async => value;
}

class _FakeAppConfig extends AppConfigNotifier {
  _FakeAppConfig(this.initial);

  final AppConfig initial;

  @override
  AppConfig build() => initial;

  @override
  Future<AppConfig> update(
    AppConfig Function(AppConfig current) updater,
  ) async {
    state = updater(state);
    return state;
  }
}

class _FakeProxies extends ProxiesNotifier {
  _FakeProxies(this.initial);

  final ProxiesSnapshot initial;
  final List<String> selections = <String>[];
  int refreshes = 0;

  @override
  Future<ProxiesSnapshot> build() async => initial;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<void> select(String group, String node) async {
    selections.add('$group/$node');
    final current = state.value;
    if (current != null) {
      state = AsyncValue<ProxiesSnapshot>.data(
        current.withSelection(group, node),
      );
    }
  }
}

ProxiesSnapshot _snapshot() => snapshotOf(
  groups: <ProxyGroup>[
    proxyGroup(
      'Proxy',
      members: <String>['HK 01', 'JP 02', 'SG 03'],
      now: 'HK 01',
    ),
    proxyGroup(
      'Auto',
      members: <String>['HK 01', 'JP 02'],
      type: 'URLTest',
      now: 'JP 02',
    ),
  ],
  nodes: <ProxyNode>[
    node('HK 01', delay: 120),
    node('JP 02', delay: 330),
    node('SG 03', failed: true),
  ],
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await primeProxyL10n();
  });
  tearDown(AikoL10n.resetForTests);

  Future<_FakeProxies> pumpPage(
    WidgetTester tester, {
    CoreState coreState = CoreState.running,
    OutboundMode mode = OutboundMode.rule,
    AppConfig config = AppConfig.defaults,
    ProxiesSnapshot? snapshot,
  }) async {
    final proxies = _FakeProxies(snapshot ?? _snapshot());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreStatusProvider.overrideWith(
            () => _FakeCoreStatus(
              CoreStatus(state: coreState, startedAt: DateTime.utc(2026)),
            ),
          ),
          outboundModeProvider.overrideWith(() => _FakeOutboundMode(mode)),
          appConfigProvider.overrideWith(() => _FakeAppConfig(config)),
          proxiesProvider.overrideWith(() => proxies),
        ],
        child: hostProxyPage(const ProxiesPage()),
      ),
    );
    await tester.pumpAndSettle();
    return proxies;
  }

  testWidgets(
    'a stopped core explains itself instead of showing an empty grid',
    (WidgetTester tester) async {
      await pumpPage(tester, coreState: CoreState.stopped);

      expect(find.text('No proxy groups'), findsOneWidget);
      expect(
        find.text('Start the core with a profile that defines proxy groups.'),
        findsOneWidget,
      );
      expect(find.byType(ProxyCard), findsNothing);
    },
  );

  testWidgets('direct mode says so rather than offering a pointless choice', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, mode: OutboundMode.direct);

    expect(find.text('Direct Mode'), findsOneWidget);
    expect(find.byType(ProxyCard), findsNothing);
  });

  testWidgets('the tab view opens on the first group and lists its nodes', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Proxy Groups & Nodes'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Proxy'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Auto'), findsOneWidget);
    expect(find.byType(ProxyCard), findsNWidgets(3));
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('tapping a node selects it through the core controller', (
    WidgetTester tester,
  ) async {
    final proxies = await pumpPage(tester);

    await tester.tap(find.text('JP 02'));
    await tester.pumpAndSettle();

    expect(proxies.selections, <String>['Proxy/JP 02']);
  });

  testWidgets('search narrows the grid without touching the group list', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'jp');
    await tester.pumpAndSettle();

    expect(find.byType(ProxyCard), findsOneWidget);
    expect(find.text('JP 02'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Auto'), findsOneWidget);
  });

  testWidgets('clearing the search restores every node', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byType(ProxyCard), findsNothing);

    await tester.tap(find.byIcon(Icons.search_off_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ProxyCard), findsNWidgets(3));
  });

  testWidgets('hide-unavailable drops the node that failed its probe', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      config: AppConfig.defaults.copyWith(hideUnavailableProxies: true),
    );

    expect(find.byType(ProxyCard), findsNWidgets(2));
    expect(find.text('SG 03'), findsNothing);
  });

  testWidgets('the options sheet switches the page to the accordion', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    expect(find.byType(ProxyGroupHeader), findsNothing);

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(ChoiceChip),
        matching: find.text('Proxy Groups & Nodes'),
      ),
    );
    await tester.pumpAndSettle();

    // Close the sheet and look at the page behind it.
    Navigator.of(tester.element(find.byType(ProxiesPage))).pop();
    await tester.pumpAndSettle();

    expect(find.byType(ProxyGroupHeader), findsNWidgets(2));
    expect(
      find.byType(ProxyCard),
      findsNothing,
      reason: 'the accordion starts collapsed',
    );

    await tester.tap(find.text('Proxy'));
    await tester.pumpAndSettle();
    expect(find.byType(ProxyCard), findsNWidgets(3));
  });

  testWidgets('pull to refresh re-reads the proxy list', (
    WidgetTester tester,
  ) async {
    final proxies = await pumpPage(tester);

    await tester.fling(find.byType(ProxyCard).first, const Offset(0, 320), 800);
    await tester.pumpAndSettle();

    expect(proxies.refreshes, greaterThan(0));
  });

  testWidgets('every icon button on the page carries a tooltip', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);

    for (final IconButton button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(
        button.tooltip,
        isNotNull,
        reason: 'unlabelled icon buttons are unreachable by screen reader',
      );
    }
    // And the page really is the AikoBox shell, not a bare Scaffold.
    expect(find.byType(AikoScaffold), findsOneWidget);
  });
}
