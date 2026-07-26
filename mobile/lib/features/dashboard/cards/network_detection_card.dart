import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../widgets/widgets.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_format.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// Network detection: a latency probe against the configured targets.
///
/// Port of the desktop network page's latency section — the same three
/// allow-listed endpoints, plus whatever the delay-test URL has been set to,
/// each measured with the configured delay-test timeout. A failed probe shows
/// the [DelayChip]'s failure glyph rather than a fabricated number.
class NetworkDetectionCard extends ConsumerWidget {
  const NetworkDetectionCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<LatencyProbeResult>> probes = ref.watch(
      networkLatencyProvider,
    );
    final List<LatencyProbeResult> results =
        probes.value ?? const <LatencyProbeResult>[];
    final bool busy =
        probes.isLoading || results.any((LatencyProbeResult r) => r.pending);

    final List<int> measured = <int>[
      for (final LatencyProbeResult result in results)
        if (result.delayMs case final int delay) delay,
    ];
    final int? average = measured.isEmpty
        ? null
        : (measured.reduce((int a, int b) => a + b) / measured.length).round();

    return DashboardCard(
      icon: Icons.network_check_rounded,
      label: l10n.t('network.latency.title'),
      lines: 2,
      semanticLabel: l10n.t('network.latency.title'),
      onTap: dashboardOpen(ref, DashboardDestination.networkInfo),
      headerActions: <Widget>[
        IconButton(
          onPressed: busy
              ? null
              : () => ref.read(networkLatencyProvider.notifier).refresh(),
          tooltip: l10n.t('common.refresh'),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (results.isEmpty)
            Text(
              busy ? l10n.t('common.loading') : l10n.t('network.noData'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...<Widget>[
            for (final LatencyProbeResult result in results)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        result.target.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DelayChip(
                      // A failed probe reports 0, which DelayChip renders as
                      // its failure glyph; a pending one gets the spinner.
                      delay: result.pending ? null : (result.delayMs ?? 0),
                      testing: result.pending,
                      dense: true,
                      unitLabel: l10n.t('unit.ms'),
                    ),
                  ],
                ),
              ),
            if (average != null)
              DashboardKeyValue(
                label: l10n.t('network.latency.average'),
                value: formatDelay(l10n, average),
              ),
          ],
        ],
      ),
    );
  }
}
