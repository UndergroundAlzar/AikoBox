import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_format.dart';
import '../dashboard_navigation.dart';
import '../dashboard_providers.dart';

/// The linked sing-box version, and how much memory it is using.
///
/// The desktop card had a restart button; there is no equivalent here on
/// purpose. Restarting the core on Android means tearing down the tunnel
/// interface, which is what the FAB is for — a second, less obvious control
/// that does the same disruptive thing is a trap.
class CoreInfoCard extends ConsumerWidget {
  const CoreInfoCard({super.key, this.status = CardStatus.colSpan1});

  final CardStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AsyncValue<String> version = ref.watch(coreVersionProvider);
    final MemoryPoint? memory = ref.watch(memoryProvider).value;

    return DashboardCard(
      icon: Icons.memory_rounded,
      label: l10n.t('mihomo.coreVersion'),
      lines: 1,
      semanticLabel: l10n.t('mihomo.coreVersion'),
      onTap: dashboardOpen(ref, DashboardDestination.coreSettings),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DashboardMetric(
            value: switch (version) {
              AsyncData<String>(:final String value) when value.isNotEmpty =>
                value,
              AsyncError<String>() => l10n.t('common.unknown'),
              _ => kDashboardNoValue,
            },
          ),
          if (status == CardStatus.colSpan2 || memory != null)
            DashboardKeyValue(
              label: l10n.t('dashboard.memory'),
              value: memory == null
                  ? kDashboardNoValue
                  : formatBytes(l10n, memory.inuse),
            ),
        ],
      ),
    );
  }
}
