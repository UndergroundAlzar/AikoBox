/// The grid the two proxy views share: one delegate, one cell.
///
/// Both views render the same cells at the same geometry; all that differs is
/// whether the grid lives in a sliver (accordion) or fills a tab page.
library;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'proxies_prefs.dart';
import 'proxy_card.dart';
import 'proxy_layout.dart';
import 'proxy_strings.dart';

/// A group plus everything the page decided about it this frame.
@immutable
class ProxyGroupSection {
  const ProxyGroupSection({
    required this.group,
    required this.nodes,
    this.expanded = true,
    this.testing = false,
  });

  final ProxyGroup group;

  /// Members after search, hide-unavailable and sort.
  final List<ProxyNodeView> nodes;

  /// Accordion state. Always true in the tab view.
  final bool expanded;

  /// A group URL test is in flight.
  final bool testing;

  String get name => group.name;

  /// Only a `Selector` takes a manual pick; URLTest, Fallback, LoadBalance and
  /// Relay decide for themselves and must not be overridden by a tap.
  bool get selectable => group.isSelectable;

  /// Position of `group.now` in [nodes], or `-1` when the current pick is
  /// filtered out.
  int get currentIndex => indexOfCurrentNode(nodes, group);

  ProxyGroupExtent get extent =>
      ProxyGroupExtent(itemCount: nodes.length, expanded: expanded);
}

typedef ProxyNodeCallback =
    void Function(ProxyGroupSection section, ProxyNodeView node);

typedef ProxyGroupCallback = void Function(ProxyGroupSection section);

/// Second line of a group header: the group's kind and what it routes through
/// right now, falling back to the member count for a group that has not picked
/// anything yet.
String proxyGroupSubtitle(ProxyGroupSection section, ProxyStrings strings) {
  final now = section.group.now.trim();
  if (now.isEmpty) {
    return '${section.group.type} · ${strings.nodeCount(section.group.all.length)}';
  }
  return '${section.group.type} · $now';
}

/// Screen-reader description of a group header.
String proxyGroupSemantics(ProxyGroupSection section, ProxyStrings strings) =>
    <String>[
      section.name,
      section.group.type,
      strings.nodeCount(section.group.all.length),
    ].join(', ');

/// Fixed-column grid at the contract's geometry: 8 px both axes, an explicit
/// main-axis extent so the scroll offset can be computed rather than measured.
SliverGridDelegate proxyGridDelegate({
  required int columns,
  required double itemHeight,
}) => SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: columns,
  mainAxisSpacing: kProxyGridSpacing,
  crossAxisSpacing: kProxyGridSpacing,
  mainAxisExtent: itemHeight,
);

/// Binds one [ProxyNodeView] to a [ProxyCard], deciding selection, the
/// auto-picked badge and whether tapping does anything at all.
class ProxyGridCell extends StatelessWidget {
  const ProxyGridCell({
    super.key,
    required this.section,
    required this.node,
    required this.density,
    required this.strings,
    required this.testing,
    required this.onSelect,
    required this.onTestNode,
  });

  final ProxyGroupSection section;
  final ProxyNodeView node;
  final ProxyCardDensity density;
  final ProxyStrings strings;

  /// A probe against this node is running.
  final bool testing;

  final ProxyNodeCallback onSelect;
  final ProxyNodeCallback onTestNode;

  @override
  Widget build(BuildContext context) {
    final selected = node.name == section.group.now;
    final computed = selected && !section.selectable;

    return ProxyCard(
      view: node,
      density: density,
      selected: selected,
      computed: computed,
      testing: testing,
      testTooltip: strings.testNode,
      semanticLabel: <String>[
        node.name,
        node.node.type,
        if (selected) strings.current,
      ].join(', '),
      onTap: section.selectable ? () => onSelect(section, node) : null,
      onTestDelay: () => onTestNode(section, node),
    );
  }
}
