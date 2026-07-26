import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/widgets.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_format.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// Live upload / download rate with a one-minute sparkline.
///
/// Port of the desktop's connection sider card, which drew the same rolling
/// window behind its two rate readouts. Up and down share one vertical scale
/// so the two lines are directly comparable, which is the whole point of
/// plotting them together.
class NetworkSpeedCard extends ConsumerWidget {
  const NetworkSpeedCard({super.key, this.status = CardStatus.colSpan2});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final List<TrafficPoint> history = ref.watch(trafficHistoryProvider);
    final bool wide = status == CardStatus.colSpan2;

    final TrafficPoint latest = history.isEmpty
        ? TrafficPoint.zero
        : history.last;
    final bool idle = history.isEmpty;

    final Widget up = DashboardMetric(
      value: idle ? kDashboardNoValue : formatSpeed(l10n, latest.up),
      caption: l10n.t('dashboard.speed.upload'),
      valueColor: colors.upload,
      icon: Icons.arrow_upward_rounded,
    );
    final Widget down = DashboardMetric(
      value: idle ? kDashboardNoValue : formatSpeed(l10n, latest.down),
      caption: l10n.t('dashboard.speed.download'),
      valueColor: colors.download,
      icon: Icons.arrow_downward_rounded,
    );

    return DashboardCard(
      icon: Icons.speed_rounded,
      label: l10n.t('dashboard.speed.title'),
      lines: 2,
      semanticLabel: l10n.t('dashboard.speed.title'),
      onTap: dashboardOpen(ref, DashboardDestination.connections),
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
          const SizedBox(height: 10),
          SizedBox(
            height: wide ? 48 : 34,
            child: idle
                ? Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      l10n.t('dashboard.speed.idle'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Sparkline(
                    series: <SparklineSeries>[
                      SparklineSeries(
                        values: <double>[
                          for (final TrafficPoint point in history)
                            point.down.toDouble(),
                        ],
                        color: colors.download,
                      ),
                      SparklineSeries(
                        values: <double>[
                          for (final TrafficPoint point in history)
                            point.up.toDouble(),
                        ],
                        color: colors.upload,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
