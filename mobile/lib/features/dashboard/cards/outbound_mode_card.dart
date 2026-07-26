import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_error.dart';

/// Rule / Global / Direct, as radios.
///
/// The desktop uses a tab strip; FlClash uses a `RadioGroup` of list items and
/// that is what §6 asks for here. Selection is optimistic —
/// `OutboundModeNotifier.setMode` publishes the new mode before the core
/// confirms and rolls back on failure — so the radio moves the instant it is
/// tapped.
///
/// The radios are disabled while the core is down: `PATCH /configs` has
/// nowhere to go, and a control that silently does nothing is worse than one
/// that is visibly unavailable.
class OutboundModeCard extends ConsumerWidget {
  const OutboundModeCard({super.key, this.status = CardStatus.colSpan2});

  final CardStatus status;

  static const Map<OutboundMode, String> _labelKeys = <OutboundMode, String>{
    OutboundMode.rule: 'outbound.modes.rule',
    OutboundMode.global: 'outbound.modes.global',
    OutboundMode.direct: 'outbound.modes.direct',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    final AsyncValue<OutboundMode> mode = ref.watch(outboundModeProvider);
    final OutboundMode current = mode.value ?? OutboundMode.rule;
    final bool wide = status == CardStatus.colSpan2;

    Future<void> select(OutboundMode next) async {
      if (!running || next == current) return;
      try {
        await ref.read(outboundModeProvider.notifier).setMode(next);
      } catch (error) {
        if (!context.mounted) return;
        await showDashboardErrorSheet(context, error);
      }
    }

    final List<Widget> tiles = <Widget>[
      for (final OutboundMode value in OutboundMode.values)
        _ModeTile(
          value: value,
          label: l10n.t(_labelKeys[value]!),
          enabled: running,
          selected: value == current,
          onTap: () => select(value),
        ),
    ];

    return DashboardCard(
      icon: Icons.call_split_rounded,
      label: l10n.t('outbound.title'),
      lines: 2,
      semanticLabel: l10n.t('outbound.title'),
      child: RadioGroup<OutboundMode>(
        groupValue: current,
        onChanged: (OutboundMode? value) {
          if (value != null) select(value);
        },
        child: wide
            ? Row(
                children: <Widget>[
                  for (final Widget tile in tiles) Expanded(child: tile),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: tiles,
              ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.value,
    required this.label,
    required this.enabled,
    required this.selected,
    required this.onTap,
  });

  final OutboundMode value;
  final String label;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color foreground = !enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Radio<OutboundMode>(
              value: value,
              enabled: enabled,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
