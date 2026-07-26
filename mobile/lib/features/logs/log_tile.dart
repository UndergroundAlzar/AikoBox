/// One log line.
///
/// A card per line, the way the desktop draws it, would be 60 % chrome on a
/// phone. This is a flat row: a colour-coded severity pill, a `HH:MM:SS` stamp
/// and the message, with a hairline underneath. Tapping copies the line.
library;

import 'package:flutter/material.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../connections/format.dart';
import 'logs_controller.dart';

/// Foreground/background pair for a severity pill.
({Color foreground, Color background}) logLevelColors(
  BuildContext context,
  LogLevel level,
) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final AikoStatusColors status = AikoStatusColors.of(context);
  return switch (level) {
    LogLevel.error => (
      foreground: status.onBadContainer,
      background: status.badContainer,
    ),
    LogLevel.warning => (
      foreground: status.onWarnContainer,
      background: status.warnContainer,
    ),
    LogLevel.info => (
      foreground: scheme.onPrimaryContainer,
      background: scheme.primaryContainer,
    ),
    LogLevel.debug || LogLevel.silent => (
      foreground: status.onNeutralContainer,
      background: status.neutralContainer,
    ),
  };
}

/// The plain-text form of a line, which is what "copy" puts on the clipboard.
String logLineAsText(AikoL10n l10n, LogLine line) =>
    '${formatClockTime(line.time)} '
    '[${l10n.t(logLevelLabelKey(line.severity))}] '
    '${line.payload}';

class LogTile extends StatelessWidget {
  const LogTile({super.key, required this.line, required this.onCopy});

  final LogLine line;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = context.l10n;
    final ({Color background, Color foreground}) colors = logLevelColors(
      context,
      line.severity,
    );

    return InkWell(
      onTap: onCopy,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AikoDims.pagePadding,
          8,
          AikoDims.pagePadding,
          8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: ShapeDecoration(
                    color: colors.background,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    l10n.t(logLevelLabelKey(line.severity)),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatClockTime(line.time),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              line.payload,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
