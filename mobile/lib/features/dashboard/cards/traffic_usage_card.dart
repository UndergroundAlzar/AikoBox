import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../theme/app_theme.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_format.dart';
import '../dashboard_navigation.dart';

/// Cumulative bytes for the current session, plus any subscription quota the
/// proxy providers report.
///
/// The desktop's usage sider card only showed provider quotas; the session
/// totals come from FlClash's traffic-usage tile. Both are here because they
/// answer the same question — "how much have I used" — at two different
/// timescales, and neither is worth a card of its own on a phone.
class TrafficUsageCard extends ConsumerWidget {
  const TrafficUsageCard({super.key, this.status = CardStatus.colSpan2});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final bool wide = status == CardStatus.colSpan2;

    final ({int up, int down})? totals = ref.watch(totalTrafficProvider).value;
    final List<ProviderInfo> quotas = <ProviderInfo>[
      for (final ProviderInfo provider
          in ref.watch(proxyProvidersProvider).value?.values ??
              const Iterable<ProviderInfo>.empty())
        if (provider.subscription != null && provider.subscription!.total > 0)
          provider,
    ];

    final Widget up = DashboardMetric(
      value: totals == null ? kDashboardNoValue : formatBytes(l10n, totals.up),
      caption: l10n.t('traffic.upload'),
      valueColor: colors.upload,
      icon: Icons.arrow_upward_rounded,
    );
    final Widget down = DashboardMetric(
      value: totals == null
          ? kDashboardNoValue
          : formatBytes(l10n, totals.down),
      caption: l10n.t('traffic.download'),
      valueColor: colors.download,
      icon: Icons.arrow_downward_rounded,
    );

    return DashboardCard(
      icon: Icons.data_usage_rounded,
      label: l10n.t('sider.cards.traffic'),
      lines: wide ? 2 : 1,
      semanticLabel: l10n.t('sider.cards.traffic'),
      onTap: dashboardOpen(ref, DashboardDestination.trafficStats),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (wide)
            Row(
              children: <Widget>[
                Expanded(child: up),
                const SizedBox(width: 12),
                Expanded(child: down),
              ],
            )
          else ...<Widget>[up, const SizedBox(height: 6), down],
          if (wide)
            for (final ProviderInfo provider in quotas)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _QuotaBar(provider: provider),
              ),
        ],
      ),
    );
  }
}

/// One provider's subscription allowance: used / total, a bar, and the expiry.
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.provider});

  final ProviderInfo provider;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final AikoL10n l10n = context.l10n;
    final SubscriptionUsage usage = provider.subscription!;

    final int? percent = usagePercent(used: usage.used, total: usage.total);
    final DateTime? expiresAt = usage.expiresAt;
    final bool expired =
        expiresAt != null && expiresAt.isBefore(DateTime.now());

    // Same thresholds as the desktop card: amber past 70 %, red past 90 % or
    // once the subscription has run out.
    final Color barColor = expired || (percent ?? 0) >= 90
        ? colors.bad
        : (percent ?? 0) >= 70
        ? colors.warn
        : theme.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                provider.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.t(
                  'profiles.traffic.usage',
                  args: <String, Object?>{
                    'used': formatBytes(l10n, usage.used),
                    'total': formatBytes(l10n, usage.total),
                  },
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (percent ?? 0) / 100,
            minHeight: 4,
            backgroundColor: colors.neutralContainer,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
        const SizedBox(height: 2),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Text(
            expiresAt == null
                ? l10n.t('sider.cards.neverExpire')
                : expired
                ? l10n.t('profiles.traffic.expired')
                : formatDate(expiresAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: expired ? colors.bad : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
