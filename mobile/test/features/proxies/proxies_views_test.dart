import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/proxies/proxies_list_view.dart';
import 'package:aikobox_mobile/features/proxies/proxies_prefs.dart';
import 'package:aikobox_mobile/features/proxies/proxies_tab_view.dart';
import 'package:aikobox_mobile/features/proxies/proxy_card.dart';
import 'package:aikobox_mobile/features/proxies/proxy_grid.dart';
import 'package:aikobox_mobile/features/proxies/proxy_group_header.dart';
import 'package:aikobox_mobile/features/proxies/proxy_layout.dart';
import 'package:aikobox_mobile/features/proxies/proxy_strings.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'harness.dart';

final ProxyStrings _strings = ProxyStrings(
  testGroup: 'Test this group',
  testNode: 'Test',
  locate: 'Locate',
  current: 'Current',
  nodeCount: (int count) => '$count nodes',
);

ProxiesSnapshotFixture _fixture() {
  final snapshot = snapshotOf(
    groups: <ProxyGroup>[
      proxyGroup('Proxy', members: <String>['HK 01', 'JP 02'], now: 'HK 01'),
      proxyGroup(
        'Auto',
        members: <String>['HK 01', 'JP 02'],
        type: 'URLTest',
        now: 'JP 02',
      ),
    ],
    nodes: <ProxyNode>[node('HK 01', delay: 120), node('JP 02', delay: 330)],
  );
  return ProxiesSnapshotFixture(snapshot);
}

class ProxiesSnapshotFixture {
  ProxiesSnapshotFixture(this.snapshot);

  final ProxiesSnapshot snapshot;

  ProxyGroupSection section(String name, {bool expanded = true}) {
    final proxyGroup = snapshot.groupNamed(name)!;
    return ProxyGroupSection(
      group: proxyGroup,
      nodes: visibleProxyNodes(snapshot: snapshot, group: proxyGroup),
      expanded: expanded,
    );
  }
}

void main() {
  setUp(primeProxyL10n);
  tearDown(AikoL10n.resetForTests);

  group('ProxyGroupHeader', () {
    testWidgets('shows the group, its type and its current pick', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        hostProxyWidget(
          const ProxyGroupHeader(
            name: 'Proxy',
            subtitle: 'Selector · HK 01',
            locateTooltip: 'Locate',
            testTooltip: 'Test this group',
            expanded: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('Selector · HK 01'), findsOneWidget);
    });

    testWidgets('the whole header toggles, so the chevron needs no tooltip', (
      WidgetTester tester,
    ) async {
      var toggles = 0;
      await tester.pumpWidget(
        hostProxyWidget(
          ProxyGroupHeader(
            name: 'Proxy',
            subtitle: 'Selector · HK 01',
            locateTooltip: 'Locate',
            testTooltip: 'Test this group',
            expanded: false,
            onToggle: () => toggles++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Proxy'));
      expect(toggles, 1);
    });

    testWidgets('locate and test are separate, tooltipped buttons', (
      WidgetTester tester,
    ) async {
      var located = 0;
      var tested = 0;
      await tester.pumpWidget(
        hostProxyWidget(
          ProxyGroupHeader(
            name: 'Proxy',
            subtitle: 'Selector · HK 01',
            locateTooltip: 'Locate',
            testTooltip: 'Test this group',
            expanded: true,
            onLocate: () => located++,
            onTest: () => tested++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Locate'));
      await tester.tap(find.byTooltip('Test this group'));
      expect(located, 1);
      expect(tested, 1);
    });

    testWidgets('a running sweep disables the button and spins it', (
      WidgetTester tester,
    ) async {
      var tested = 0;
      await tester.pumpWidget(
        hostProxyWidget(
          ProxyGroupHeader(
            name: 'Proxy',
            subtitle: 'Selector · HK 01',
            locateTooltip: 'Locate',
            testTooltip: 'Test this group',
            expanded: true,
            testing: true,
            onTest: () => tested++,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Test this group'));
      expect(tested, 0);
    });
  });

  group('ProxiesListView', () {
    Future<void> pumpList(
      WidgetTester tester, {
      required List<ProxyGroupSection> sections,
      ProxyNodeCallback? onSelectNode,
      ProxyGroupCallback? onToggleGroup,
    }) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        hostProxyWidget(
          ProxiesListView(
            scrollController: controller,
            sections: sections,
            columns: 2,
            itemHeight: 88,
            density: ProxyCardDensity.shrink,
            strings: _strings,
            testingNodes: const <String>{},
            onToggleGroup: onToggleGroup ?? (_) {},
            onTestGroup: (_) {},
            onLocateGroup: (_) {},
            onSelectNode: onSelectNode ?? (_, _) {},
            onTestNode: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a collapsed group shows its header and nothing else', (
      WidgetTester tester,
    ) async {
      final fixture = _fixture();
      await pumpList(
        tester,
        sections: <ProxyGroupSection>[
          fixture.section('Proxy', expanded: false),
        ],
      );

      expect(find.byType(ProxyGroupHeader), findsOneWidget);
      expect(find.byType(ProxyCard), findsNothing);
    });

    testWidgets('an expanded group renders one card per member', (
      WidgetTester tester,
    ) async {
      final fixture = _fixture();
      await pumpList(
        tester,
        sections: <ProxyGroupSection>[fixture.section('Proxy')],
      );

      expect(find.byType(ProxyCard), findsNWidgets(2));
      expect(find.text('HK 01'), findsOneWidget);
      expect(find.text('JP 02'), findsOneWidget);
    });

    testWidgets('tapping a card in a Selector group reports the choice', (
      WidgetTester tester,
    ) async {
      final fixture = _fixture();
      String? chosen;
      await pumpList(
        tester,
        sections: <ProxyGroupSection>[fixture.section('Proxy')],
        onSelectNode: (ProxyGroupSection section, ProxyNodeView node) =>
            chosen = '${section.name}/${node.name}',
      );

      await tester.tap(find.text('JP 02'));
      expect(chosen, 'Proxy/JP 02');
    });

    testWidgets('tapping a card in a URLTest group reports nothing', (
      WidgetTester tester,
    ) async {
      final fixture = _fixture();
      var selections = 0;
      await pumpList(
        tester,
        sections: <ProxyGroupSection>[fixture.section('Auto')],
        onSelectNode: (_, _) => selections++,
      );

      await tester.tap(find.text('HK 01'));
      await tester.pump();
      expect(
        selections,
        0,
        reason: 'URLTest picks for itself; a tap must not override it',
      );
    });

    testWidgets('the header reports a toggle', (WidgetTester tester) async {
      final fixture = _fixture();
      String? toggled;
      await pumpList(
        tester,
        sections: <ProxyGroupSection>[
          fixture.section('Proxy', expanded: false),
        ],
        onToggleGroup: (ProxyGroupSection section) => toggled = section.name,
      );

      await tester.tap(find.text('Proxy'));
      expect(toggled, 'Proxy');
    });
  });

  group('ProxiesTabView', () {
    testWidgets('one tab per group, the active one showing its grid', (
      WidgetTester tester,
    ) async {
      final fixture = _fixture();
      final sections = <ProxyGroupSection>[
        fixture.section('Proxy'),
        fixture.section('Auto'),
      ];
      final controllers = <String, ScrollController>{};
      addTearDown(() {
        for (final controller in controllers.values) {
          controller.dispose();
        }
      });

      await tester.pumpWidget(
        hostProxyWidget(
          DefaultTabController(
            length: sections.length,
            child: Builder(
              builder: (BuildContext context) => ProxiesTabView(
                tabController: DefaultTabController.of(context),
                sections: sections,
                columns: 2,
                itemHeight: 88,
                density: ProxyCardDensity.shrink,
                strings: _strings,
                testingNodes: const <String>{},
                scrollControllerFor: (String name) =>
                    controllers.putIfAbsent(name, ScrollController.new),
                onTestGroup: (_) {},
                onLocateGroup: (_) {},
                onSelectNode: (_, _) {},
                onTestNode: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Tab), findsNWidgets(2));
      // The group's own subtitle sits under the strip, above its grid.
      expect(find.text('Selector · HK 01'), findsOneWidget);
      expect(find.byType(ProxyCard), findsNWidgets(2));
    });
  });
}
