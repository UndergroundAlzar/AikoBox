/// One row of the connections list.
///
/// The desktop shows `process → destination` on one line. A phone row is half
/// that wide, so the destination gets the title to itself and the origin drops
/// into the pill row underneath. Direction is carried by icons rather than by
/// `→ ↑ ↓` glyphs, which keeps the row correct under `fa-IR`'s RTL layout.
library;

import 'package:flutter/material.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'connection_fields.dart';
import 'format.dart';

/// A compact rounded label. Small enough that four fit on one phone row.
class ConnectionPill extends StatelessWidget {
  const ConnectionPill({
    super.key,
    required this.child,
    this.background,
    this.foreground,
    this.borderColor,
  });

  ConnectionPill.text(
    String label, {
    Key? key,
    Color? background,
    Color? foreground,
    Color? borderColor,
  }) : this(
         key: key,
         background: background,
         foreground: foreground,
         borderColor: borderColor,
         child: _PillText(label),
       );

  final Widget child;
  final Color? background;
  final Color? foreground;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color resolvedForeground =
        foreground ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: background ?? Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color:
                borderColor ??
                (background == null
                    ? theme.colorScheme.outlineVariant
                    : Colors.transparent),
          ),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: theme.textTheme.labelSmall?.copyWith(color: resolvedForeground),
        child: IconTheme.merge(
          data: IconThemeData(size: 12, color: resolvedForeground),
          child: child,
        ),
      ),
    );
  }
}

class _PillText extends StatelessWidget {
  const _PillText(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
}

/// An up/down pair inside one pill: `↑ 1.20 MB  ↓ 4.60 MB`, with the arrows as
/// icons so nothing has to be translated or mirrored.
class ConnectionTrafficPill extends StatelessWidget {
  const ConnectionTrafficPill({
    super.key,
    required this.up,
    required this.down,
    this.perSecond = false,
  });

  final int up;
  final int down;

  /// Renders both numbers as rates rather than totals.
  final bool perSecond;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final AikoStatusColors status = AikoStatusColors.of(context);
    final String upText = perSecond
        ? formatSpeedText(l10n, up)
        : formatTrafficText(l10n, up);
    final String downText = perSecond
        ? formatSpeedText(l10n, down)
        : formatTrafficText(l10n, down);

    return ConnectionPill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.arrow_upward_rounded, color: status.upload),
          const SizedBox(width: 2),
          // Flexible, not bare: `941.9 MB` twice plus two icons is wider than a
          // 320 dp phone's card, and a pill that overflows is a red-and-yellow
          // stripe in release-mode screenshots.
          Flexible(child: _PillText(upText)),
          const SizedBox(width: 8),
          Icon(Icons.arrow_downward_rounded, color: status.download),
          const SizedBox(width: 2),
          Flexible(child: _PillText(downText)),
        ],
      ),
    );
  }
}

/// One connection, as a tappable card.
class ConnectionTile extends StatelessWidget {
  const ConnectionTile({
    super.key,
    required this.connection,
    required this.isActive,
    required this.now,
    required this.onOpenDetail,
    required this.onDismiss,
  });

  final ConnectionInfo connection;

  /// Drives both the accent colour and whether the trailing button closes the
  /// connection or just forgets the record.
  final bool isActive;

  /// Evaluated once per page build so every row's age agrees.
  final DateTime now;

  final VoidCallback onOpenDetail;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = context.l10n;
    final ConnectionFields fields = connectionFieldsOf(connection);

    final bool hasSpeed =
        connection.uploadSpeed != 0 || connection.downloadSpeed != 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CommonCard(
        onTap: onOpenDetail,
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        semanticLabel: fields.destinationLabel,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          fields.destinationLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatElapsedClock(now.difference(connection.start)),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      ConnectionPill.text(
                        fields.typeLabel,
                        background: isActive
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        foreground: isActive
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      if (fields.originLabel.isNotEmpty)
                        ConnectionPill(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                fields.process.isNotEmpty
                                    ? Icons.apps_rounded
                                    : Icons.smartphone_rounded,
                              ),
                              const SizedBox(width: 4),
                              Flexible(child: _PillText(fields.originLabel)),
                            ],
                          ),
                        ),
                      if (connection.outbound.isNotEmpty)
                        ConnectionPill.text(connection.outbound),
                      ConnectionTrafficPill(
                        up: connection.upload,
                        down: connection.download,
                      ),
                      if (hasSpeed)
                        ConnectionTrafficPill(
                          up: connection.uploadSpeed,
                          down: connection.downloadSpeed,
                          perSecond: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              color: isActive ? scheme.onSurfaceVariant : scheme.error,
              tooltip: isActive
                  ? l10n.t('common.close')
                  : l10n.t('common.remove'),
              icon: Icon(
                isActive ? Icons.close_rounded : Icons.delete_outline_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
