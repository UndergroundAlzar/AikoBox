import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_navigation.dart';

/// How many log lines are buffered, and at what level they are being kept.
///
/// The clear action is here because it is the one log operation that is
/// unambiguous from a card — everything else (filtering, exporting, reading)
/// needs the log screen.
class LogCard extends ConsumerWidget {
  const LogCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  static const Map<LogLevel, String> _levelKeys = <LogLevel, String>{
    LogLevel.silent: 'mihomo.silent',
    LogLevel.error: 'mihomo.error',
    LogLevel.warning: 'mihomo.warning',
    LogLevel.info: 'mihomo.info',
    LogLevel.debug: 'mihomo.debug',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final List<LogLine> lines = ref.watch(logsProvider);
    final LogLevel level = ref.watch(
      appConfigProvider.select((AppConfig config) => config.logLevel),
    );

    return DashboardCard(
      icon: Icons.receipt_long_rounded,
      label: l10n.t('sider.cards.logs'),
      lines: 1,
      semanticLabel: l10n.t('sider.cards.logs'),
      onTap: dashboardOpen(ref, DashboardDestination.logs),
      headerActions: <Widget>[
        if (lines.isNotEmpty)
          IconButton(
            onPressed: () => ref.read(logsProvider.notifier).clear(),
            tooltip: l10n.t('logs.clear'),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(value: '${lines.length}'),
          Text(
            lines.isEmpty
                ? l10n.t('logs.empty')
                : l10n.t(_levelKeys[level] ?? 'mihomo.info'),
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
