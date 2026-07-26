/// The arithmetic behind the proxies page: how many columns fit, how tall a
/// cell is, which nodes survive the filters, and where a given node sits in the
/// scroll extent.
///
/// Everything here is a pure function of its arguments so the grid can be
/// reasoned about — and tested — without building a widget tree or starting a
/// core.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/app_theme.dart';
import 'proxies_prefs.dart';

/// Gutter between grid cells, both axes. FlClash uses 8 and the contract pins
/// it, so it is a constant rather than a theme value.
const double kProxyGridSpacing = 8;

/// Fixed height of a group header in the accordion.
///
/// Fixed on purpose: [proxyListScrollOffset] computes an exact scroll position
/// from it, which is what makes locate-current-node land on the right row
/// without the target having been built yet.
const double kProxyGroupHeaderHeight = 72;

/// Vertical gap between two groups in the accordion.
const double kProxyGroupGap = 8;

/// Smallest height a cell may take, whatever the text metrics say.
const double kProxyCardMinHeight = 48;

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// Columns for a grid [width] logical pixels wide.
///
/// `max((width / 250).ceil(), 2)` — the contract's formula — then FlClash's
/// ±1 layout nudge. An explicit [proxyCols] (the desktop's `proxyCols` setting,
/// `'auto'` or a digit) wins outright, because a user who picked "three
/// columns" meant three.
int proxyColumnsForWidth(
  double width, {
  ProxiesLayout layout = ProxiesLayout.standard,
  String proxyCols = 'auto',
  double cellWidth = AikoDims.proxyCellWidth,
}) {
  final explicit = int.tryParse(proxyCols.trim());
  if (explicit != null) return explicit.clamp(1, 8);

  if (!width.isFinite || width <= 0 || cellWidth <= 0) {
    return (2 + layout.columnDelta).clamp(1, 8);
  }
  final base = (width / cellWidth).ceil();
  return ((base < 2 ? 2 : base) + layout.columnDelta).clamp(1, 8);
}

double _lineHeight(TextStyle? style, double fallbackSize, TextScaler scaler) {
  final size = scaler.scale(style?.fontSize ?? fallbackSize);
  return size * (style?.height ?? 1.4);
}

/// Height of one grid cell.
///
/// Port of FlClash's `getItemHeight`: two lines of `bodyMedium` for the name, a
/// line of `bodySmall` for the type, plus padding — and, for
/// [ProxyCardDensity.expand], a `labelSmall` line for the delay pill on its own
/// row. Text-scale aware, so a user at 200 % font size does not get clipped
/// cards.
double proxyCardHeight({
  required TextTheme textTheme,
  required ProxyCardDensity density,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final bodyMedium = _lineHeight(textTheme.bodyMedium, 14, textScaler);
  final bodySmall = _lineHeight(textTheme.bodySmall, 12, textScaler);
  final labelSmall = _lineHeight(textTheme.labelSmall, 11, textScaler);

  final base = 16 + bodyMedium * 2 + bodySmall + 8 + 4;
  final height = switch (density) {
    ProxyCardDensity.expand => base + labelSmall + 6,
    ProxyCardDensity.shrink => base,
    ProxyCardDensity.min => base - bodyMedium,
  };
  return height < kProxyCardMinHeight ? kProxyCardMinHeight : height;
}

/// Height the grid of one group occupies, excluding its header.
double proxyGroupGridHeight({
  required int itemCount,
  required int columns,
  required double itemHeight,
  double spacing = kProxyGridSpacing,
}) {
  if (itemCount <= 0 || columns <= 0) return 0;
  final rows = (itemCount / columns).ceil();
  return rows * itemHeight + (rows - 1) * spacing;
}

/// One group's contribution to the accordion's scroll extent.
@immutable
class ProxyGroupExtent {
  const ProxyGroupExtent({required this.itemCount, required this.expanded});

  final int itemCount;
  final bool expanded;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyGroupExtent &&
          other.itemCount == itemCount &&
          other.expanded == expanded;

  @override
  int get hashCode => Object.hash(itemCount, expanded);

  @override
  String toString() =>
      'ProxyGroupExtent($itemCount item(s), ${expanded ? 'open' : 'closed'})';
}

/// Scroll offset that puts the row holding item [itemIndex] of group
/// [groupIndex] at the top of the accordion viewport.
///
/// Computed rather than measured because the row is virtualised: on a 500-node
/// subscription the target cell does not exist yet when the user taps "locate".
double proxyListScrollOffset({
  required List<ProxyGroupExtent> groups,
  required int groupIndex,
  required int itemIndex,
  required int columns,
  required double itemHeight,
  double headerHeight = kProxyGroupHeaderHeight,
  double spacing = kProxyGridSpacing,
  double groupGap = kProxyGroupGap,
  double topPadding = AikoDims.pagePadding,
}) {
  if (groupIndex < 0 || groupIndex >= groups.length || columns <= 0) return 0;

  var offset = topPadding;
  for (var i = 0; i < groupIndex; i++) {
    final group = groups[i];
    offset += headerHeight;
    if (group.expanded && group.itemCount > 0) {
      offset +=
          spacing +
          proxyGroupGridHeight(
            itemCount: group.itemCount,
            columns: columns,
            itemHeight: itemHeight,
            spacing: spacing,
          );
    }
    offset += groupGap;
  }

  offset += headerHeight;
  if (itemIndex > 0) {
    offset += spacing + (itemIndex ~/ columns) * (itemHeight + spacing);
  }
  return offset < 0 ? 0 : offset;
}

/// Scroll offset for the tab view's single-group grid.
double proxyGridScrollOffset({
  required int itemIndex,
  required int columns,
  required double itemHeight,
  double spacing = kProxyGridSpacing,
  double topPadding = AikoDims.pagePadding,
}) {
  if (itemIndex <= 0 || columns <= 0) return 0;
  return topPadding + (itemIndex ~/ columns) * (itemHeight + spacing);
}

// ---------------------------------------------------------------------------
// Node list
// ---------------------------------------------------------------------------

/// A node as the grid needs it: the raw outbound plus the delay actually in
/// force, which may be a measurement this session took rather than whatever the
/// last `/proxies` poll carried.
@immutable
class ProxyNodeView {
  const ProxyNodeView({
    required this.node,
    required this.delay,
    required this.tested,
    required this.isGroup,
  });

  final ProxyNode node;

  /// Milliseconds, or `null` when the node has never answered a probe.
  final int? delay;

  /// A probe has been run against this node at some point.
  final bool tested;

  /// The member is itself a proxy group, not a leaf outbound.
  final bool isGroup;

  String get name => node.name;

  /// A measured failure, as opposed to "never measured".
  bool get failed => tested && (delay == null || delay! <= 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyNodeView &&
          other.node == node &&
          other.delay == delay &&
          other.tested == tested &&
          other.isGroup == isGroup;

  @override
  int get hashCode => Object.hash(node, delay, tested, isGroup);

  @override
  String toString() => 'ProxyNodeView($name, ${delay ?? '-'} ms)';
}

/// Case-insensitive substring match. Port of `includesIgnoreCase`.
bool proxyNameMatches(String name, String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return true;
  return name.toLowerCase().contains(trimmed.toLowerCase());
}

/// Resolves the members of [group] into the list the grid renders.
///
/// Applies, in the desktop's order: the search query, hide-unavailable, then
/// the sort. [delayOverrides] holds measurements this session took — a key
/// present with a `null` value means "probed and it failed", which is why the
/// map is consulted with `containsKey` rather than a null check.
List<ProxyNodeView> visibleProxyNodes({
  required ProxiesSnapshot snapshot,
  required ProxyGroup group,
  String query = '',
  bool hideUnavailable = false,
  ProxySortOrder sort = ProxySortOrder.byDefault,
  Map<String, int?> delayOverrides = const <String, int?>{},
}) {
  final views = <ProxyNodeView>[];
  for (final node in snapshot.membersOf(group.name)) {
    if (!proxyNameMatches(node.name, query)) continue;

    final overridden = delayOverrides.containsKey(node.name);
    final delay = overridden ? delayOverrides[node.name] : node.delay;
    final tested = overridden || node.history.isNotEmpty;
    final isGroup = snapshot.groupNamed(node.name) != null;

    if (hideUnavailable &&
        !isGroup &&
        tested &&
        (delay == null || delay <= 0)) {
      continue;
    }
    views.add(
      ProxyNodeView(
        node: node,
        delay: delay == null || delay <= 0 ? null : delay,
        tested: tested,
        isGroup: isGroup,
      ),
    );
  }
  return sortProxyNodes(views, sort);
}

/// Sorts [views] without disturbing the relative order of equal elements.
///
/// `List.sort` is not stable in Dart, and an unstable sort on a delay tie makes
/// the grid shuffle every time a measurement lands. `mergeSort` is.
List<ProxyNodeView> sortProxyNodes(
  List<ProxyNodeView> views,
  ProxySortOrder sort,
) {
  final sorted = List<ProxyNodeView>.of(views);
  switch (sort) {
    case ProxySortOrder.byDefault:
      return sorted;
    case ProxySortOrder.byName:
      mergeSort<ProxyNodeView>(
        sorted,
        compare: (a, b) => compareNatural(a.name, b.name),
      );
      return sorted;
    case ProxySortOrder.byDelay:
      mergeSort<ProxyNodeView>(sorted, compare: _byDelay);
      return sorted;
  }
}

/// Fastest first, then the ones that failed a probe, then the never-measured.
///
/// Matches `proxies.tsx`, which checks `history.length === 0` before it looks at
/// the delay and therefore sinks untested nodes below failed ones.
int _byDelay(ProxyNodeView a, ProxyNodeView b) {
  final rankA = _delayRank(a);
  final rankB = _delayRank(b);
  if (rankA != rankB) return rankA - rankB;
  if (rankA != 0) return 0;
  return a.delay!.compareTo(b.delay!);
}

int _delayRank(ProxyNodeView view) {
  if (!view.tested) return 2;
  if (view.delay == null) return 1;
  return 0;
}

/// Index of [group]'s current pick inside [views], or `-1` when the pick is
/// filtered out (hidden by the search box, say).
int indexOfCurrentNode(List<ProxyNodeView> views, ProxyGroup group) =>
    views.indexWhere((view) => view.name == group.now);

/// Groups worth showing, in the order the page should present them.
///
/// The core marks internal groups `hidden`, and a group with no members is
/// noise. In global mode `GLOBAL` is hoisted to the front, because that is the
/// only group routing decisions actually go through — the same reorder
/// `mihomoApi.ts:mihomoGroups` does.
List<ProxyGroup> visibleProxyGroups(
  ProxiesSnapshot snapshot, {
  OutboundMode mode = OutboundMode.rule,
}) {
  final groups = <ProxyGroup>[
    for (final group in snapshot.groups)
      if (!group.hidden && group.all.isNotEmpty) group,
  ];
  if (mode != OutboundMode.global) return groups;

  final index = groups.indexWhere((group) => group.name == 'GLOBAL');
  if (index <= 0) return groups;
  return <ProxyGroup>[
    groups[index],
    ...groups.sublist(0, index),
    ...groups.sublist(index + 1),
  ];
}
