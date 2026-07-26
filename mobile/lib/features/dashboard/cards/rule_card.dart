import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// How many routing rules are in force.
///
/// Live from `GET /rules` while the core is up, and from the profile's own
/// `rules:` block while it is down, so the number does not vanish the moment
/// the tunnel stops.
class RuleCountCard extends ConsumerWidget {
  const RuleCountCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );

    final List<RuleItem>? live = running
        ? ref.watch(rulesProvider).value
        : null;
    final ProfileRuntimeSummary? summary = running
        ? null
        : ref.watch(profileRuntimeSummaryProvider).value;

    final int? count = live?.length ?? summary?.ruleCount;

    return DashboardCard(
      icon: Icons.alt_route_rounded,
      label: l10n.t('sider.cards.rules'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.rules'),
      onTap: dashboardOpen(ref, DashboardDestination.rules),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(value: count == null ? kDashboardNoValue : '$count'),
          Text(
            count == null || count == 0
                ? l10n.t('rules.empty')
                : running
                ? l10n.t('dashboard.status.running')
                : l10n.t('dashboard.core.notRunning'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
