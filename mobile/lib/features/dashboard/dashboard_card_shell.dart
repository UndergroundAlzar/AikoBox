/// The pieces every dashboard card is built from.
///
/// [DashboardCard] is a thin wrapper over the design system's `CommonCard`
/// that adds the one thing a grid needs and a single card does not: a minimum
/// height expressed in *rows*, so a grid of cards reads as a grid instead of a
/// ragged pile. FlClash does the same with a fixed `getWidgetHeight(lines)`;
/// this uses a minimum rather than a fixed height so a card can still grow
/// when the user has scaled their text up.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'dashboard_navigation.dart';

/// The tap handler for a card that opens another screen, or `null` when the
/// shell has not wired [dashboardNavigateProvider] — in which case the card
/// stays informative but stops pretending to be a button.
VoidCallback? dashboardOpen(WidgetRef ref, DashboardDestination destination) {
  final DashboardNavigate? navigate = ref.watch(dashboardNavigateProvider);
  return navigate == null ? null : () => navigate(destination);
}

/// Height of one dashboard row at 1x text scale.
///
/// FlClash uses 80 px plus a 14 px gutter; 92 with the 12 px `AikoDims`
/// gutter gives the same visual rhythm with this card's slightly taller
/// header.
const double kDashboardRowUnit = 92;

/// Minimum height for a card spanning [lines] rows.
///
/// Scales with the platform text scale so a large-text user gets taller cards
/// rather than clipped ones, damped at 1.5x — past that the grid should get
/// taller from its content, not from this floor.
double dashboardCardHeight(BuildContext context, int lines) {
  final double ratio = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
    1.0,
    1.5,
  );
  final double unit = kDashboardRowUnit * ratio;
  return lines * unit + (lines - 1) * AikoDims.gridSpacing;
}

/// A card in the dashboard grid.
///
/// [label] is already-localised display text; this widget never touches l10n.
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.icon,
    required this.label,
    required this.child,
    this.lines = 1,
    this.onTap,
    this.headerActions = const <Widget>[],
    this.semanticLabel,
    this.isError = false,
  });

  final IconData icon;
  final String label;
  final Widget child;

  /// How many grid rows tall this card is at minimum.
  final int lines;

  final VoidCallback? onTap;
  final List<Widget> headerActions;
  final String? semanticLabel;

  /// Draws the hairline and the header glyph in `colorScheme.error`.
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: dashboardCardHeight(context, lines),
      ),
      child: CommonCard(
        icon: icon,
        label: label,
        headerActions: headerActions,
        onTap: onTap,
        isError: isError,
        semanticLabel: semanticLabel,
        child: Align(alignment: AlignmentDirectional.topStart, child: child),
      ),
    );
  }
}

/// A headline number with an optional caption underneath.
class DashboardMetric extends StatelessWidget {
  const DashboardMetric({
    super.key,
    required this.value,
    this.caption,
    this.valueColor,
    this.icon,
  });

  /// Already-localised, already-formatted.
  final String value;
  final String? caption;
  final Color? valueColor;

  /// Small leading glyph, tinted to match [valueColor].
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = valueColor ?? theme.colorScheme.onSurface;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (caption != null)
          Text(
            caption!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// The desktop's bordered count `Chip`, as a header action.
class DashboardCountBadge extends StatelessWidget {
  const DashboardCountBadge({
    super.key,
    required this.label,
    this.muted = false,
  });

  /// Already-localised, already-formatted.
  final String label;

  /// Draws in `onSurfaceVariant` instead of `primary` — for a count that is
  /// not live because the core is down.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = muted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: color)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// A labelled key/value row, for the denser cards.
class DashboardKeyValue extends StatelessWidget {
  const DashboardKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  /// Already-localised.
  final String label;

  /// Already-localised, already-formatted.
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: valueColor ?? theme.colorScheme.onSurface,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The em dash every card shows when it has nothing to report.
const String kDashboardNoValue = '—';
