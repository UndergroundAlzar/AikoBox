/// The row that introduces a group: its name, what it currently routes
/// through, and the two actions that apply to the whole group.
///
/// Height is pinned to [kProxyGroupHeaderHeight]. That is not cosmetic —
/// [proxyListScrollOffset] adds it up to work out where a node sits in the
/// accordion's scroll extent, and locate-current-node has to land on a row that
/// has not been built yet.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'proxy_layout.dart';

class ProxyGroupHeader extends StatelessWidget {
  const ProxyGroupHeader({
    super.key,
    required this.name,
    required this.subtitle,
    required this.locateTooltip,
    required this.testTooltip,
    this.semanticLabel,
    this.expanded,
    this.testing = false,
    this.onToggle,
    this.onLocate,
    this.onTest,
    this.height = kProxyGroupHeaderHeight,
  });

  /// Group name, verbatim from the core.
  final String name;

  /// Second line — the group type and its current pick, already joined and
  /// localised by the caller.
  final String subtitle;

  final String locateTooltip;
  final String testTooltip;
  final String? semanticLabel;

  /// `null` in the tab view, where there is nothing to expand.
  final bool? expanded;

  /// A group URL test is running.
  final bool testing;

  final VoidCallback? onToggle;
  final VoidCallback? onLocate;
  final VoidCallback? onTest;

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: height,
      child: CommonCard(
        onTap: onToggle,
        semanticLabel: semanticLabel,
        backgroundColor: scheme.surfaceContainerLow,
        padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: locateTooltip,
              onPressed: onLocate,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.my_location_rounded, size: 20),
            ),
            ProxyGroupTestButton(
              tooltip: testTooltip,
              testing: testing,
              onPressed: onTest,
            ),
            if (expanded case final isExpanded?)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 2, end: 6),
                child: AnimatedRotation(
                  duration: AikoDims.midMotion,
                  curve: Curves.easeOut,
                  turns: isExpanded ? 0.5 : 0,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Swaps the speedometer for a spinner while the group sweep runs, keeping the
/// 48 px hit target either way so the row does not twitch.
class ProxyGroupTestButton extends StatelessWidget {
  const ProxyGroupTestButton({
    super.key,
    required this.tooltip,
    required this.testing,
    required this.onPressed,
  });

  final String tooltip;
  final bool testing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: testing ? null : onPressed,
      visualDensity: VisualDensity.compact,
      icon: testing
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            )
          : const Icon(Icons.network_ping_rounded, size: 20),
    );
  }
}
