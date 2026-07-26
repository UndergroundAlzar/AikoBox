/// The accordion: every group stacked, each one expandable in place.
///
/// This is the desktop app's proxies page. It is built out of slivers rather
/// than a chunked `ListView` of `Row`s so a 500-node group costs the same as a
/// 5-node one, and because a sliver grid gives every row an exact, predictable
/// extent — which is what [proxyListScrollOffset] relies on to scroll straight
/// to the current node without that row having been built.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'proxies_prefs.dart';
import 'proxy_grid.dart';
import 'proxy_group_header.dart';
import 'proxy_layout.dart';
import 'proxy_strings.dart';

class ProxiesListView extends StatelessWidget {
  const ProxiesListView({
    super.key,
    required this.scrollController,
    required this.sections,
    required this.columns,
    required this.itemHeight,
    required this.density,
    required this.strings,
    required this.testingNodes,
    required this.onToggleGroup,
    required this.onTestGroup,
    required this.onLocateGroup,
    required this.onSelectNode,
    required this.onTestNode,
    this.bottomPadding = AikoDims.fabClearance,
  });

  final ScrollController scrollController;
  final List<ProxyGroupSection> sections;
  final int columns;
  final double itemHeight;
  final ProxyCardDensity density;
  final ProxyStrings strings;

  /// Nodes with a probe in flight, by name.
  final Set<String> testingNodes;

  final ProxyGroupCallback onToggleGroup;
  final ProxyGroupCallback onTestGroup;
  final ProxyGroupCallback onLocateGroup;
  final ProxyNodeCallback onSelectNode;
  final ProxyNodeCallback onTestNode;

  /// Room under the last row so the shell's FAB never covers a card.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final delegate = proxyGridDelegate(
      columns: columns,
      itemHeight: itemHeight,
    );

    final slivers = <Widget>[];
    for (final section in sections) {
      slivers.add(
        SliverToBoxAdapter(
          child: ProxyGroupHeader(
            key: ValueKey<String>('proxy-group-header:${section.name}'),
            name: section.name,
            subtitle: proxyGroupSubtitle(section, strings),
            semanticLabel: proxyGroupSemantics(section, strings),
            locateTooltip: strings.locate,
            testTooltip: strings.testGroup,
            expanded: section.expanded,
            testing: section.testing,
            onToggle: () => onToggleGroup(section),
            onLocate: () => onLocateGroup(section),
            onTest: () => onTestGroup(section),
          ),
        ),
      );

      if (section.expanded && section.nodes.isNotEmpty) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.only(top: kProxyGridSpacing),
            sliver: SliverGrid(
              gridDelegate: delegate,
              delegate: SliverChildBuilderDelegate((
                BuildContext context,
                int index,
              ) {
                final node = section.nodes[index];
                return ProxyGridCell(
                  key: ValueKey<String>('${section.name}/${node.name}'),
                  section: section,
                  node: node,
                  density: density,
                  strings: strings,
                  testing: testingNodes.contains(node.name),
                  onSelect: onSelectNode,
                  onTestNode: onTestNode,
                );
              }, childCount: section.nodes.length),
            ),
          ),
        );
      }

      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: kProxyGroupGap)),
      );
    }

    return CustomScrollView(
      controller: scrollController,
      // Always scrollable so pull-to-refresh still works when the groups all
      // fit on one screen — the case where a user is most likely to reach for
      // it, because the list looks wrong.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AikoDims.pagePadding,
            AikoDims.pagePadding,
            AikoDims.pagePadding,
            bottomPadding,
          ),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }
}
