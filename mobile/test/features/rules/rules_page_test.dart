import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/rules/rules_controller.dart';
import 'package:aikobox_mobile/features/rules/rules_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const List<RuleItem> _rules = <RuleItem>[
  RuleItem(type: 'DomainSuffix', payload: 'example.com', proxy: 'PROXY'),
  RuleItem(type: 'GeoIP', payload: 'cn', proxy: 'DIRECT'),
  RuleItem(type: 'RuleSet', payload: 'ads', proxy: 'REJECT', size: 4211),
  RuleItem(type: 'Match', payload: '', proxy: 'PROXY'),
];

final Map<String, ProviderInfo> _providers = <String, ProviderInfo>{
  'ads': ProviderInfo(
    name: 'ads',
    type: 'Rule',
    vehicleType: 'HTTP',
    behavior: 'domain',
    format: 'yaml',
    ruleCount: 4211,
    updatedAt: DateTime(2026, 7, 26, 9, 30),
  ),
  'private': const ProviderInfo(
    name: 'private',
    type: 'Rule',
    vehicleType: 'File',
    behavior: 'ipcidr',
    ruleCount: 17,
  ),
};

void main() {
  late Map<String, String> en;

  setUp(() => en = loadLocaleStrings());

  ProviderContainer makeContainer({
    CoreStatus? status,
    List<RuleItem> rules = _rules,
    Map<String, ProviderInfo>? providers,
    Object? apiFailure,
  }) => ProviderContainer.test(
    overrides: [
      coreStatusProvider.overrideWith(
        () => FakeCoreStatusNotifier(status ?? runningStatus),
      ),
      rulesProvider.overrideWith((Ref ref) async => rules),
      ruleProvidersProvider.overrideWith(
        (Ref ref) async => providers ?? _providers,
      ),
      // No ClashApi in a widget test: every provider update fails, which is
      // exactly the path worth asserting on.
      clashApiProvider.overrideWith((Ref ref) async {
        throw apiFailure ?? StateError('no core in tests');
      }),
    ],
  );

  group('pure filtering', () {
    test('ruleMatchesQuery searches type, payload and proxy', () {
      const RuleItem rule = RuleItem(
        type: 'DomainSuffix',
        payload: 'example.com',
        proxy: 'PROXY',
      );
      expect(ruleMatchesQuery(rule, 'domainsuffix'), isTrue);
      expect(ruleMatchesQuery(rule, 'example'), isTrue);
      expect(ruleMatchesQuery(rule, 'proxy'), isTrue);
      expect(ruleMatchesQuery(rule, 'reject'), isFalse);
      expect(ruleMatchesQuery(rule, ''), isTrue);
    });

    test('filterRules returns the same list when nothing is typed', () {
      expect(identical(filterRules(_rules, ''), _rules), isTrue);
    });

    test('providerMatchesQuery covers every field a row shows', () {
      final ProviderInfo provider = _providers['ads']!;
      expect(providerMatchesQuery(provider, 'ads'), isTrue);
      expect(providerMatchesQuery(provider, 'http'), isTrue);
      expect(providerMatchesQuery(provider, 'domain'), isTrue);
      expect(providerMatchesQuery(provider, 'yaml'), isTrue);
      expect(providerMatchesQuery(provider, 'nope'), isFalse);
    });

    test('failureMessageKey never leaks a raw exception', () {
      expect(failureMessageKey(StateError('x')), 'error.code.E_UNKNOWN');
      expect(
        failureMessageKey(
          const AikoCoreException(
            AikoCoreException.codeCoreStartFailed,
            'boom',
          ),
        ),
        'error.code.E_CORE_START_FAILED',
      );
    });
  });

  testWidgets('lists rules with their type, payload and outbound', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const RulesPage(), container: makeContainer());

    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('DomainSuffix'), findsOneWidget);
    expect(find.text('cn'), findsOneWidget);
    expect(find.text('GeoIP'), findsOneWidget);
    // A rule-set carries its cardinality.
    expect(find.text('4211'), findsOneWidget);
    // A payload-less rule falls back to showing its type as the title.
    expect(find.text('Match'), findsWidgets);
  });

  testWidgets('the search box narrows the rule list', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const RulesPage(), container: makeContainer());

    await tester.enterText(find.byType(TextField), 'geoip');
    await tester.pumpAndSettle();

    expect(find.text('cn'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
  });

  testWidgets('says the core is not running rather than "no rules"', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const RulesPage(),
      container: makeContainer(status: CoreStatus.stopped, rules: <RuleItem>[]),
    );
    expect(find.text(en['dashboard.core.notRunning']!), findsOneWidget);
  });

  testWidgets('reports an empty rule list while the core is up', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const RulesPage(),
      container: makeContainer(rules: <RuleItem>[]),
    );
    expect(find.text(en['rules.empty']!), findsOneWidget);
  });

  testWidgets('the providers tab shows counts and last-update times', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const RulesPage(), container: makeContainer());

    await tester.tap(find.text(en['resources.ruleProviders.title']!));
    await tester.pumpAndSettle();

    expect(find.text('ads'), findsOneWidget);
    expect(find.text('private'), findsOneWidget);
    expect(find.text('4211'), findsWidgets);
    expect(find.text('17'), findsOneWidget);
    expect(find.text('HTTP'), findsOneWidget);
    expect(
      find.text(
        en['profiles.traffic.lastUpdate']!.replaceFirst(
          '{time}',
          '2026-07-26 09:30:00',
        ),
      ),
      findsOneWidget,
    );
    // A provider the core never fetched says so instead of showing epoch zero.
    expect(
      find.text(
        en['profiles.traffic.lastUpdate']!.replaceFirst(
          '{time}',
          en['common.never']!,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the providers search narrows that list too', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const RulesPage(), container: makeContainer());

    await tester.tap(find.text(en['resources.ruleProviders.title']!));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'private');
    await tester.pumpAndSettle();

    // The search field itself now reads "private", so assert on the row's own
    // fields rather than on its name.
    expect(find.text('17'), findsOneWidget);
    expect(find.text('ipcidr'), findsOneWidget);
    expect(find.text('ads'), findsNothing);
    expect(find.text('4211'), findsNothing);
  });

  testWidgets('a failed provider update is surfaced, not swallowed', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const RulesPage(), container: makeContainer());

    await tester.tap(find.text(en['resources.ruleProviders.title']!));
    await tester.pumpAndSettle();

    // By tooltip, not by icon: the app bar's own refresh uses the same glyph.
    await tester.tap(find.byTooltip(en['common.updater.update']!).first);
    await tester.pumpAndSettle();

    expect(find.text(en['error.code.E_UNKNOWN']!), findsOneWidget);
  });
}
