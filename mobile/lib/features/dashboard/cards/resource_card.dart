import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';

/// Proxy and rule providers currently loaded by the core.
class ResourceCard extends ConsumerWidget {
  const ResourceCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    final int proxyProviders =
        ref.watch(proxyProvidersProvider).value?.length ?? 0;
    final int ruleProviders =
        ref.watch(ruleProvidersProvider).value?.length ?? 0;

    return DashboardCard(
      icon: Icons.layers_rounded,
      label: l10n.t('sider.cards.resources'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.resources'),
      onTap: dashboardOpen(ref, DashboardDestination.resources),
      child: !running
          ? Text(
              l10n.t('dashboard.core.notRunning'),
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
                DashboardKeyValue(
                  label: l10n.t('resources.proxyProviders.title'),
                  value: '$proxyProviders',
                ),
                DashboardKeyValue(
                  label: l10n.t('resources.ruleProviders.title'),
                  value: '$ruleProviders',
                ),
              ],
            ),
    );
  }
}
