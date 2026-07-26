import 'package:aikobox_mobile/features/proxies/proxies_prefs.dart';
import 'package:aikobox_mobile/features/proxies/proxy_card.dart';
import 'package:aikobox_mobile/features/proxies/proxy_layout.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'harness.dart';

ProxyNodeView view(
  String name, {
  int? delay,
  bool tested = false,
  bool isGroup = false,
  bool udp = false,
}) => ProxyNodeView(
  node: node(name, udp: udp),
  delay: delay,
  tested: tested || delay != null,
  isGroup: isGroup,
);

void main() {
  setUp(primeProxyL10n);
  tearDown(AikoL10n.resetForTests);

  Future<void> pumpCard(
    WidgetTester tester, {
    required ProxyNodeView node,
    ProxyCardDensity density = ProxyCardDensity.shrink,
    bool selected = false,
    bool computed = false,
    bool testing = false,
    VoidCallback? onTap,
    VoidCallback? onTestDelay,
  }) => tester.pumpWidget(
    hostProxyWidget(
      ProxyCard(
        view: node,
        density: density,
        selected: selected,
        computed: computed,
        testing: testing,
        onTap: onTap,
        onTestDelay: onTestDelay,
        testTooltip: 'Test',
        semanticLabel: '${node.name}, ${node.node.type}',
      ),
      size: const Size(220, 110),
    ),
  );

  testWidgets('shows the node name, its type and the measured latency', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, node: view('HK 01', delay: 120));
    await tester.pumpAndSettle();

    expect(find.text('HK 01'), findsOneWidget);
    expect(find.text('Shadowsocks'), findsOneWidget);
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('an unmeasured node shows a dash, a failed one a cross', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, node: view('Never'));
    await tester.pumpAndSettle();
    expect(find.text('—'), findsOneWidget);

    await pumpCard(tester, node: view('Dead', tested: true));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('a probe in flight replaces the value with a spinner', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, node: view('HK 01', delay: 120), testing: true);
    await tester.pump();

    expect(find.text('120 ms'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the latency pill is its own tap target', (
    WidgetTester tester,
  ) async {
    var probes = 0;
    await pumpCard(
      tester,
      node: view('HK 01', delay: 120),
      onTestDelay: () => probes++,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DelayChip));
    expect(probes, 1);
  });

  testWidgets('a selectable group makes the whole card tappable', (
    WidgetTester tester,
  ) async {
    var taps = 0;
    await pumpCard(
      tester,
      node: view('HK 01', delay: 120),
      onTap: () => taps++,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('HK 01'));
    expect(taps, 1);
  });

  testWidgets('a group that picks for itself has no tap target on the card', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, node: view('HK 01', delay: 120));
    await tester.pumpAndSettle();

    final card = tester.widget<CommonCard>(find.byType(CommonCard));
    expect(card.onTap, isNull);
  });

  testWidgets('the auto-picked member of a computed group wears a badge', (
    WidgetTester tester,
  ) async {
    await pumpCard(
      tester,
      node: view('HK 01', delay: 120),
      selected: true,
      computed: true,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);

    await pumpCard(tester, node: view('HK 01', delay: 120), selected: true);
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.bolt_rounded),
      findsNothing,
      reason: 'a Selector pick is the user\'s, so it gets no "automatic" mark',
    );
  });

  testWidgets('selection is drawn on the card, not around it', (
    WidgetTester tester,
  ) async {
    await pumpCard(tester, node: view('HK 01', delay: 120), selected: true);
    await tester.pumpAndSettle();

    final card = tester.widget<CommonCard>(find.byType(CommonCard));
    expect(card.isSelected, isTrue);
  });

  testWidgets('the expanded density adds the UDP flag on its own row', (
    WidgetTester tester,
  ) async {
    await pumpCard(
      tester,
      node: view('HK 01', delay: 120, udp: true),
      density: ProxyCardDensity.expand,
    );
    await tester.pumpAndSettle();
    expect(find.text('UDP'), findsOneWidget);

    await pumpCard(tester, node: view('HK 01', delay: 120, udp: true));
    await tester.pumpAndSettle();
    expect(
      find.text('UDP'),
      findsNothing,
      reason: 'the compact densities have no room for transport flags',
    );
  });

  testWidgets('the node name never overflows its cell', (
    WidgetTester tester,
  ) async {
    await pumpCard(
      tester,
      node: view(
        '🇭🇰 Hong Kong · Premium · IEPL · x3 multiplier · node forty two',
      ),
      density: ProxyCardDensity.min,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
