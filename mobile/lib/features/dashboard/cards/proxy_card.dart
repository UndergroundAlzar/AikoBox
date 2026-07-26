import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../widgets/widgets.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';

/// The active proxy group and the node it currently points at.
///
/// The desktop card only showed how many groups there were. On a phone the one
/// thing worth knowing at a glance is which exit is carrying traffic, so the
/// group count moves into the header badge and the selection takes the body.
class ProxySelectionCard extends ConsumerWidget {
  const ProxySelectionCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    final ProxiesSnapshot snapshot =
        ref.watch(proxiesProvider).value ?? ProxiesSnapshot.empty;

    // The group a user thinks of as "the" group is the first one they can
    // actually choose in; a config of nothing but url-tests falls back to
    // whatever the core listed first.
    final ProxyGroup? group =
        snapshot.groups.firstWhereOrNull((ProxyGroup g) => g.isSelectable) ??
        snapshot.groups.firstOrNull;
    final ProxyNode? node = group == null
        ? null
        : snapshot.nodeNamed(group.now);

    return DashboardCard(
      icon: Icons.lan_rounded,
      label: l10n.t('proxies.card.title'),
      lines: 1,
      semanticLabel: l10n.t('proxies.card.title'),
      onTap: dashboardOpen(ref, DashboardDestination.proxies),
      headerActions: <Widget>[
        if (snapshot.groups.isNotEmpty)
          DashboardCountBadge(
            label: '${snapshot.groups.length}',
            muted: !running,
          ),
      ],
      child: group == null
          ? Text(
              running
                  ? l10n.t('proxies.empty.title')
                  : l10n.t('dashboard.core.notRunning'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        group.now.isEmpty ? l10n.t('common.none') : group.now,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (node != null) ...<Widget>[
                      const SizedBox(width: 8),
                      DelayChip(
                        delay: node.delay,
                        dense: true,
                        unitLabel: l10n.t('unit.ms'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}
