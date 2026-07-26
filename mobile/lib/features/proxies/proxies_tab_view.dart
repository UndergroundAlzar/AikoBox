/// One group at a time behind a scrollable tab strip.
///
/// The FlClash layout, and the better one on a phone: the grid gets the whole
/// page instead of the ~60 % an accordion leaves it, and switching group is a
/// swipe. The accordion is still there for people who want every group at once.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'proxies_prefs.dart';
import 'proxy_grid.dart';
import 'proxy_group_header.dart';
import 'proxy_strings.dart';

/// Gap between the group action bar and the first row of cards.
const double kProxyTabGridTopPadding = 8;

class ProxiesTabView extends StatelessWidget {
  const ProxiesTabView({
    super.key,
    required this.tabController,
    required this.sections,
    required this.columns,
    required this.itemHeight,
    required this.density,
    required this.strings,
    required this.testingNodes,
    required this.scrollControllerFor,
    required this.onTestGroup,
    required this.onLocateGroup,
    required this.onSelectNode,
    required this.onTestNode,
    this.bottomPadding = AikoDims.fabClearance,
  });

  /// Owned by the page, because its length has to track [sections].
  final TabController tabController;

  final List<ProxyGroupSection> sections;
  final int columns;
  final double itemHeight;
  final ProxyCardDensity density;
  final ProxyStrings strings;
  final Set<String> testingNodes;

  /// One controller per group, kept alive by the page so a tab remembers where
  /// it was scrolled to and locate-current-node has something to drive.
  final ScrollController Function(String groupName) scrollControllerFor;

  final ProxyGroupCallback onTestGroup;
  final ProxyGroupCallback onLocateGroup;
  final ProxyNodeCallback onSelectNode;
  final ProxyNodeCallback onTestNode;

  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: <Widget>[
        TabBar(
          controller: tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: AikoDims.pagePadding),
          labelStyle: theme.textTheme.titleSmall,
          unselectedLabelStyle: theme.textTheme.titleSmall,
          tabs: <Widget>[
            for (final section in sections) Tab(text: section.name),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: <Widget>[
              for (final section in sections)
                _ProxyTabPane(
                  key: ValueKey<String>('proxy-tab-pane:${section.name}'),
                  section: section,
                  columns: columns,
                  itemHeight: itemHeight,
                  density: density,
                  strings: strings,
                  testingNodes: testingNodes,
                  scrollController: scrollControllerFor(section.name),
                  onTestGroup: onTestGroup,
                  onLocateGroup: onLocateGroup,
                  onSelectNode: onSelectNode,
                  onTestNode: onTestNode,
                  bottomPadding: bottomPadding,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProxyTabPane extends StatelessWidget {
  const _ProxyTabPane({
    super.key,
    required this.section,
    required this.columns,
    required this.itemHeight,
    required this.density,
    required this.strings,
    required this.testingNodes,
    required this.scrollController,
    required this.onTestGroup,
    required this.onLocateGroup,
    required this.onSelectNode,
    required this.onTestNode,
    required this.bottomPadding,
  });

  final ProxyGroupSection section;
  final int columns;
  final double itemHeight;
  final ProxyCardDensity density;
  final ProxyStrings strings;
  final Set<String> testingNodes;
  final ScrollController scrollController;
  final ProxyGroupCallback onTestGroup;
  final ProxyGroupCallback onLocateGroup;
  final ProxyNodeCallback onSelectNode;
  final ProxyNodeCallback onTestNode;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _GroupActionBar(
          subtitle: proxyGroupSubtitle(section, strings),
          semanticLabel: proxyGroupSemantics(section, strings),
          locateTooltip: strings.locate,
          testTooltip: strings.testGroup,
          testing: section.testing,
          onLocate: () => onLocateGroup(section),
          onTest: () => onTestGroup(section),
        ),
        Expanded(
          child: GridView.builder(
            controller: scrollController,
            // See ProxiesListView: a short group still has to accept the
            // pull-to-refresh drag.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              AikoDims.pagePadding,
              kProxyTabGridTopPadding,
              AikoDims.pagePadding,
              bottomPadding,
            ),
            gridDelegate: proxyGridDelegate(
              columns: columns,
              itemHeight: itemHeight,
            ),
            itemCount: section.nodes.length,
            itemBuilder: (BuildContext context, int index) {
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
            },
          ),
        ),
      ],
    );
  }
}

/// Slim row under the tab strip: what the group routes through, plus the same
/// two actions the accordion header carries.
class _GroupActionBar extends StatelessWidget {
  const _GroupActionBar({
    required this.subtitle,
    required this.semanticLabel,
    required this.locateTooltip,
    required this.testTooltip,
    required this.testing,
    required this.onLocate,
    required this.onTest,
  });

  final String subtitle;
  final String semanticLabel;
  final String locateTooltip;
  final String testTooltip;
  final bool testing;
  final VoidCallback onLocate;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AikoDims.pagePadding,
          end: 4,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                label: semanticLabel,
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: locateTooltip,
              onPressed: onLocate,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.my_location_rounded, size: 20),
            ),
            ProxyGroupTestButton(
              tooltip: testTooltip,
              testing: testing,
              onPressed: onTest,
            ),
          ],
        ),
      ),
    );
  }
}
