import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../theme/app_theme.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// What the active profile asks for in its `sniffer:` block.
///
/// Same reasoning as the DNS card: the desktop's `controlSniff` switch has no
/// Android counterpart, so this reports rather than pretends to toggle.
class SniffCard extends ConsumerWidget {
  const SniffCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final ProfileRuntimeSummary? value = ref
        .watch(profileRuntimeSummaryProvider)
        .value;

    final String headline;
    final Color headlineColor;
    if (value == null || !value.hasProfile) {
      headline = kDashboardNoValue;
      headlineColor = theme.colorScheme.onSurfaceVariant;
    } else if (value.snifferEnabled) {
      headline = l10n.t('common.enabled');
      headlineColor = colors.good;
    } else {
      headline = l10n.t('common.disabled');
      headlineColor = theme.colorScheme.onSurfaceVariant;
    }

    final List<String> protocols = value?.sniffProtocols ?? const <String>[];

    return DashboardCard(
      icon: Icons.travel_explore_rounded,
      label: l10n.t('sider.cards.sniff'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.sniff'),
      onTap: dashboardOpen(ref, DashboardDestination.sniffer),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(value: headline, valueColor: headlineColor),
          Text(
            protocols.isNotEmpty
                ? protocols.join(' · ')
                : value == null || !value.hasProfile
                ? l10n.t('dashboard.noProfile.title')
                : l10n.t('sniffer.enable'),
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
