/// The dashboard card registry, and the rules that turn a persisted layout
/// into a grid.
///
/// The keys are the desktop app's, so `AppConfig.cardOrder` and
/// `AppConfig.cardStatus` carry straight over from `kDefaultCardOrder` in
/// `core/models.dart`. One key is new — [kLatencyCardKey] — because the
/// desktop had no network-detection sider card; anything the persisted order
/// does not mention is appended in registry order, so a layout saved before a
/// card existed still shows it rather than silently dropping it.
library;

import 'package:flutter/material.dart';

import '../../core/providers.dart';
import '../../widgets/widgets.dart';
import 'cards/connection_card.dart';
import 'cards/core_info_card.dart';
import 'cards/dns_card.dart';
import 'cards/log_card.dart';
import 'cards/network_detection_card.dart';
import 'cards/network_speed_card.dart';
import 'cards/outbound_mode_card.dart';
import 'cards/profile_card.dart';
import 'cards/proxy_card.dart';
import 'cards/resource_card.dart';
import 'cards/rule_card.dart';
import 'cards/sniff_card.dart';
import 'cards/traffic_usage_card.dart';

/// The Android-only network-detection card. Not one of the desktop's keys.
const String kLatencyCardKey = 'latency';

/// One entry in the dashboard's card registry.
@immutable
class DashboardCardSpec {
  const DashboardCardSpec({
    required this.key,
    required this.labelKey,
    required this.icon,
    required this.defaultStatus,
    required this.builder,
  });

  /// The key persisted in `AppConfig.cardOrder` / `cardStatus`.
  final String key;

  /// l10n key for the card's name, used by the layout editor.
  final String labelKey;

  /// Glyph shown next to that name in the layout editor.
  final IconData icon;

  /// Where a reset puts this card.
  final CardStatus defaultStatus;

  /// Builds the card at the span the user has chosen.
  final Widget Function(CardStatus status) builder;
}

/// Every card the dashboard can show, in the order a fresh install gets.
final List<DashboardCardSpec> kDashboardCards =
    List<DashboardCardSpec>.unmodifiable(<DashboardCardSpec>[
      DashboardCardSpec(
        key: 'network',
        labelKey: 'dashboard.speed.title',
        icon: Icons.speed_rounded,
        defaultStatus: CardStatus.colSpan2,
        builder: (CardStatus status) => NetworkSpeedCard(status: status),
      ),
      DashboardCardSpec(
        key: 'mode',
        labelKey: 'outbound.title',
        icon: Icons.call_split_rounded,
        defaultStatus: CardStatus.colSpan2,
        builder: (CardStatus status) => OutboundModeCard(status: status),
      ),
      DashboardCardSpec(
        key: 'profile',
        labelKey: 'sider.cards.profiles',
        icon: Icons.folder_rounded,
        defaultStatus: CardStatus.colSpan2,
        builder: (CardStatus status) => DashboardProfileCard(status: status),
      ),
      DashboardCardSpec(
        key: 'proxy',
        labelKey: 'proxies.card.title',
        icon: Icons.lan_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => ProxySelectionCard(status: status),
      ),
      DashboardCardSpec(
        key: 'connection',
        labelKey: 'sider.cards.connections',
        icon: Icons.link_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => ConnectionCountCard(status: status),
      ),
      DashboardCardSpec(
        key: 'usage',
        labelKey: 'sider.cards.traffic',
        icon: Icons.data_usage_rounded,
        defaultStatus: CardStatus.colSpan2,
        builder: (CardStatus status) => TrafficUsageCard(status: status),
      ),
      DashboardCardSpec(
        key: kLatencyCardKey,
        labelKey: 'network.latency.title',
        icon: Icons.network_check_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => NetworkDetectionCard(status: status),
      ),
      DashboardCardSpec(
        key: 'mihomo',
        labelKey: 'mihomo.coreVersion',
        icon: Icons.memory_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => CoreInfoCard(status: status),
      ),
      DashboardCardSpec(
        key: 'rule',
        labelKey: 'sider.cards.rules',
        icon: Icons.alt_route_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => RuleCountCard(status: status),
      ),
      DashboardCardSpec(
        key: 'dns',
        labelKey: 'sider.cards.dns',
        icon: Icons.dns_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => DnsCard(status: status),
      ),
      DashboardCardSpec(
        key: 'sniff',
        labelKey: 'sider.cards.sniff',
        icon: Icons.travel_explore_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => SniffCard(status: status),
      ),
      DashboardCardSpec(
        key: 'resource',
        labelKey: 'sider.cards.resources',
        icon: Icons.layers_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => ResourceCard(status: status),
      ),
      DashboardCardSpec(
        key: 'log',
        labelKey: 'sider.cards.logs',
        icon: Icons.receipt_long_rounded,
        defaultStatus: CardStatus.colSpan1,
        builder: (CardStatus status) => LogCard(status: status),
      ),
    ]);

/// The registry entry for [key], or `null` for a key this build does not know
/// — a layout saved by a newer version, for instance.
DashboardCardSpec? dashboardCardSpec(String key) {
  for (final DashboardCardSpec spec in kDashboardCards) {
    if (spec.key == key) return spec;
  }
  return null;
}

/// Turns a persisted order into the order the grid actually renders.
///
/// Unknown keys are dropped and missing ones appended, so the result always
/// lists every card in [kDashboardCards] exactly once.
List<String> resolveDashboardCardOrder(List<String> savedOrder) {
  final List<String> resolved = <String>[];
  final Set<String> seen = <String>{};
  for (final String key in savedOrder) {
    if (dashboardCardSpec(key) == null || !seen.add(key)) continue;
    resolved.add(key);
  }
  for (final DashboardCardSpec spec in kDashboardCards) {
    if (seen.add(spec.key)) resolved.add(spec.key);
  }
  return List<String>.unmodifiable(resolved);
}

/// The layout a fresh install starts from, and what "Restore default layout"
/// puts back.
Map<String, CardStatus> defaultDashboardCardStatus() => <String, CardStatus>{
  for (final DashboardCardSpec spec in kDashboardCards)
    spec.key: spec.defaultStatus,
};

/// The grid items for [order], honouring each card's persisted span and
/// hidden state.
List<StaggeredGridItem> buildDashboardGridItems({
  required List<String> order,
  required AppConfig config,
}) {
  final List<StaggeredGridItem> items = <StaggeredGridItem>[];
  for (final String key in order) {
    final DashboardCardSpec? spec = dashboardCardSpec(key);
    if (spec == null) continue;
    final CardStatus status = config.statusOfCard(key);
    if (!status.isVisible) continue;
    items.add(
      StaggeredGridItem(
        child: KeyedSubtree(
          key: ValueKey<String>('dashboard-card-$key'),
          child: spec.builder(status),
        ),
        columnSpan: status.columnSpan,
      ),
    );
  }
  return items;
}
