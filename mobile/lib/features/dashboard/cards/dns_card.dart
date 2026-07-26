import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../theme/app_theme.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// What the active profile asks for in its `dns:` block.
///
/// The desktop card was a switch over `controlDns`, AikoBox's own DNS
/// override. That setting has no Android counterpart in `AppConfig`, so
/// rather than render a switch that toggles nothing this reports what the
/// profile actually declares and hands the user to the DNS screen to change
/// it.
class DnsCard extends ConsumerWidget {
  const DnsCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  static const Map<String, String> _modeKeys = <String, String>{
    'fake-ip': 'dns.enhancedMode.fakeIp',
    'redir-host': 'dns.enhancedMode.redirHost',
    'normal': 'dns.enhancedMode.normal',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final AsyncValue<ProfileRuntimeSummary> summary = ref.watch(
      profileRuntimeSummaryProvider,
    );
    final ProfileRuntimeSummary? value = summary.value;

    final String headline;
    final Color headlineColor;
    if (value == null || !value.hasProfile) {
      headline = kDashboardNoValue;
      headlineColor = theme.colorScheme.onSurfaceVariant;
    } else if (value.dnsEnabled) {
      headline = l10n.t('common.enabled');
      headlineColor = colors.good;
    } else {
      headline = l10n.t('common.disabled');
      headlineColor = theme.colorScheme.onSurfaceVariant;
    }

    final String? modeKey = _modeKeys[value?.dnsMode.toLowerCase()];

    return DashboardCard(
      icon: Icons.dns_rounded,
      label: l10n.t('sider.cards.dns'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.dns'),
      onTap: dashboardOpen(ref, DashboardDestination.dns),
      headerActions: <Widget>[
        if ((value?.dnsServerCount ?? 0) > 0)
          DashboardCountBadge(label: '${value!.dnsServerCount}'),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(value: headline, valueColor: headlineColor),
          Text(
            modeKey != null
                ? l10n.t(modeKey)
                : value == null || !value.hasProfile
                ? l10n.t('dashboard.noProfile.title')
                : l10n.t('dns.enhancedMode.title'),
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
