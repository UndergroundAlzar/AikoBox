/// One cell of the proxies grid.
///
/// The "Surfboard-like" card: node name over its type and a latency pill, on a
/// [CommonCard] that fills with `primaryContainer` when it is the group's
/// current pick. Height is imposed by the grid delegate
/// ([proxyCardHeight]), so the layout here never measures — it gives the name
/// the slack and pins the metadata row to the bottom.
library;

import 'package:flutter/material.dart';

import '../../widgets/widgets.dart';
import 'proxies_prefs.dart';
import 'proxy_layout.dart';

/// Horizontal inset of the card body. Matches FlClash's 12 px.
const double kProxyCardPadding = 12;

class ProxyCard extends StatelessWidget {
  const ProxyCard({
    super.key,
    required this.view,
    required this.density,
    required this.selected,
    this.computed = false,
    this.testing = false,
    this.onTap,
    this.onTestDelay,
    this.testTooltip,
    this.semanticLabel,
  });

  /// The node plus the delay actually in force for it.
  final ProxyNodeView view;

  final ProxyCardDensity density;

  /// This node is the group's `now`.
  final bool selected;

  /// The group picked this node itself (URLTest / Fallback / LoadBalance /
  /// Relay), so the choice is not the user's and cannot be changed by tapping.
  final bool computed;

  /// A probe against this node is in flight.
  final bool testing;

  /// `null` for a group that does not accept a manual selection.
  final VoidCallback? onTap;

  /// Probes this one node.
  final VoidCallback? onTestDelay;

  /// Already-localised tooltip for the latency pill.
  final String? testTooltip;

  /// Already-localised description of the whole cell, including the fact that
  /// the group picked this node itself when [computed] is set.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Color nameColor = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final Color subtleColor = selected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant;

    // The pill needs 0 (not null) to paint a failure: null means "never
    // measured" and shows an em dash instead of the red cross.
    final int? pillDelay = view.failed ? 0 : view.delay;

    final Widget delayPill = DelayChip(
      delay: pillDelay,
      testing: testing,
      dense: true,
      onTap: onTestDelay,
      tooltip: testTooltip,
    );

    final Widget name = Text(
      view.name,
      maxLines: density == ProxyCardDensity.min ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(color: nameColor),
    );

    final Widget typeLabel = Text(
      view.node.type,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(color: subtleColor),
    );

    final Widget footer = density == ProxyCardDensity.expand
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(child: typeLabel),
                  if (view.node.udp) ...<Widget>[
                    const SizedBox(width: 4),
                    _ProtocolBadge(label: 'UDP', color: subtleColor),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: delayPill,
              ),
            ],
          )
        : Row(
            children: <Widget>[
              Flexible(child: typeLabel),
              const SizedBox(width: 6),
              delayPill,
            ],
          );

    return CommonCard(
      radius: 12,
      isSelected: selected,
      onTap: onTap,
      semanticLabel: semanticLabel,
      backgroundColor: scheme.surfaceContainerLow,
      borderColor: selected ? scheme.primary : scheme.outlineVariant,
      padding: const EdgeInsets.symmetric(
        horizontal: kProxyCardPadding,
        vertical: 8,
      ),
      selectedOverlay: computed
          ? _ComputedBadge(
              color: scheme.secondaryContainer,
              foreground: scheme.onSecondaryContainer,
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Align(alignment: AlignmentDirectional.topStart, child: name),
          ),
          const SizedBox(height: 4),
          footer,
        ],
      ),
    );
  }
}

/// A transport flag (`UDP`) shown next to the outbound type in expanded cards.
/// The token is a protocol name, not prose, so it is the same in every locale.
class _ProtocolBadge extends StatelessWidget {
  const _ProtocolBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: color.withValues(alpha: 0.4)),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontSize: 9,
          height: 1.1,
        ),
      ),
    );
  }
}

/// Corner mark on the member a URLTest/Fallback/LoadBalance/Relay group picked
/// for itself, so the fill does not read as "you chose this".
///
/// Carries no tooltip on purpose: [CommonCard] renders the overlay inside an
/// [IgnorePointer], so a tooltip here would never fire. The same fact reaches
/// screen readers through the card's `semanticLabel`.
class _ComputedBadge extends StatelessWidget {
  const _ComputedBadge({required this.color, required this.foreground});

  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topEnd,
    child: Container(
      margin: const EdgeInsets.all(6),
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
      child: Icon(Icons.bolt_rounded, size: 10, color: foreground),
    ),
  );
}
