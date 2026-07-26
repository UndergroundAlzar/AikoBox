import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/proxies/proxies_options_sheet.dart';
import 'package:aikobox_mobile/features/proxies/proxies_prefs.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(primeProxyL10n);
  tearDown(AikoL10n.resetForTests);

  Future<void> pumpSheet(
    WidgetTester tester, {
    ProxiesViewType viewType = ProxiesViewType.tab,
    ProxySortOrder sortOrder = ProxySortOrder.byDefault,
    bool hideUnavailable = false,
    ProxyCardDensity density = ProxyCardDensity.shrink,
    ProxiesLayout layout = ProxiesLayout.standard,
    String proxyCols = 'auto',
    ValueChanged<ProxiesViewType>? onViewTypeChanged,
    ValueChanged<ProxySortOrder>? onSortOrderChanged,
    ValueChanged<bool>? onHideUnavailableChanged,
    ValueChanged<ProxyCardDensity>? onDensityChanged,
    ValueChanged<ProxiesLayout>? onLayoutChanged,
    ValueChanged<String>? onProxyColsChanged,
    VoidCallback? onExpandAll,
    VoidCallback? onCollapseAll,
  }) async {
    // A tall surface so every group is on screen; the sheet scrolls on a real
    // phone, and a scrolled-away chip cannot be tapped by the tester.
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      hostProxyWidget(
        ProxiesOptionsSheet(
          viewType: viewType,
          sortOrder: sortOrder,
          hideUnavailable: hideUnavailable,
          density: density,
          layout: layout,
          proxyCols: proxyCols,
          onViewTypeChanged: onViewTypeChanged ?? (ProxiesViewType _) {},
          onSortOrderChanged: onSortOrderChanged ?? (ProxySortOrder _) {},
          onHideUnavailableChanged: onHideUnavailableChanged ?? (bool _) {},
          onDensityChanged: onDensityChanged ?? (ProxyCardDensity _) {},
          onLayoutChanged: onLayoutChanged ?? (ProxiesLayout _) {},
          onProxyColsChanged: onProxyColsChanged ?? (String _) {},
          onExpandAll: onExpandAll,
          onCollapseAll: onCollapseAll,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ChoiceChip chipLabelled(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)),
  );

  testWidgets('every option group is on screen with its label', (
    WidgetTester tester,
  ) async {
    await pumpSheet(tester);

    // Sort, card size, columns and layout, all from assets/locales.
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Delay'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Card size'), findsOneWidget);
    expect(find.text('Expanded'), findsOneWidget);
    expect(find.text('Proxy Display Columns'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Layout'), findsOneWidget);
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Hide Unavailable Proxies'), findsOneWidget);
  });

  testWidgets('the current value is the selected chip in each group', (
    WidgetTester tester,
  ) async {
    await pumpSheet(
      tester,
      sortOrder: ProxySortOrder.byDelay,
      density: ProxyCardDensity.min,
      layout: ProxiesLayout.tight,
      proxyCols: '3',
    );

    expect(chipLabelled(tester, 'Delay').selected, isTrue);
    expect(chipLabelled(tester, 'Default').selected, isFalse);
    expect(chipLabelled(tester, 'Minimal').selected, isTrue);
    expect(chipLabelled(tester, 'Tight').selected, isTrue);
    expect(chipLabelled(tester, 'Three Columns').selected, isTrue);
  });

  testWidgets('picking a chip reports the new value', (
    WidgetTester tester,
  ) async {
    ProxySortOrder? sort;
    ProxyCardDensity? density;
    String? columns;
    await pumpSheet(
      tester,
      onSortOrderChanged: (ProxySortOrder value) => sort = value,
      onDensityChanged: (ProxyCardDensity value) => density = value,
      onProxyColsChanged: (String value) => columns = value,
    );

    await tester.tap(find.text('Delay'));
    await tester.tap(find.text('Minimal'));
    await tester.tap(find.text('Two Columns'));

    expect(sort, ProxySortOrder.byDelay);
    expect(density, ProxyCardDensity.min);
    expect(columns, '2');
  });

  testWidgets('the layout nudge is disabled once columns are pinned', (
    WidgetTester tester,
  ) async {
    var changes = 0;
    await pumpSheet(
      tester,
      proxyCols: '3',
      onLayoutChanged: (ProxiesLayout _) => changes++,
    );

    expect(chipLabelled(tester, 'Loose').onSelected, isNull);
    await tester.tap(find.text('Loose'));
    expect(changes, 0);

    await pumpSheet(tester, onLayoutChanged: (ProxiesLayout _) => changes++);
    await tester.tap(find.text('Loose'));
    expect(changes, 1);
  });

  testWidgets('hide-unavailable is a switch, not a three-way button', (
    WidgetTester tester,
  ) async {
    bool? value;
    await pumpSheet(
      tester,
      onHideUnavailableChanged: (bool next) => value = next,
    );

    await tester.tap(find.text('Hide Unavailable Proxies'));
    expect(value, isTrue);
  });

  testWidgets('expand/collapse all appear only for the accordion', (
    WidgetTester tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('Expand all'), findsNothing);
    expect(find.text('Collapse all'), findsNothing);

    var expanded = 0;
    await pumpSheet(
      tester,
      viewType: ProxiesViewType.list,
      onExpandAll: () => expanded++,
      onCollapseAll: () {},
    );
    expect(find.text('Expand all'), findsOneWidget);
    expect(find.text('Collapse all'), findsOneWidget);

    await tester.tap(find.text('Expand all'));
    expect(expanded, 1);
  });

  testWidgets('the view names come from the bundle, never from a raw key', (
    WidgetTester tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('proxies.view.tab'), findsNothing);
    expect(find.text('proxies.view.list'), findsNothing);
    expect(find.byType(ChoiceChip), findsNWidgets(2 + 3 + 3 + 5 + 3));
  });
}
