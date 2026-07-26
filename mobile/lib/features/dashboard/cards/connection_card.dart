import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';

/// How many connections the core is currently carrying.
class ConnectionCountCard extends ConsumerWidget {
  const ConnectionCountCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    final List<ConnectionInfo>? connections = ref
        .watch(connectionsProvider)
        .value;

    return DashboardCard(
      icon: Icons.link_rounded,
      label: l10n.t('sider.cards.connections'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.connections'),
      onTap: dashboardOpen(ref, DashboardDestination.connections),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(
            value: connections == null
                ? kDashboardNoValue
                : '${connections.length}',
          ),
          Text(
            !running
                ? l10n.t('dashboard.core.notRunning')
                : connections == null || connections.isEmpty
                ? l10n.t('connections.empty')
                : l10n.plural('plural.connections', connections.length),
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
