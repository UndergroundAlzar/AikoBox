/// Rows for the rules page: one matched rule, and one rule provider.
library;

import 'package:flutter/material.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../connections/format.dart';

/// A small rounded label, matching the pills on the connections page.
class RulePill extends StatelessWidget {
  const RulePill({
    super.key,
    required this.label,
    this.background,
    this.foreground,
    this.icon,
  });

  final String label;
  final Color? background;
  final Color? foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color resolved = foreground ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: background ?? Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: background == null
                ? theme.colorScheme.outlineVariant
                : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: resolved),
            const SizedBox(width: 4),
          ],
          // A rule payload can be arbitrarily long; the pill ellipsizes rather
          // than pushing past the card edge.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: resolved),
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry of `GET /rules`.
///
/// The desktop also shows hit counts and a per-rule enable switch. Neither is
/// portable: both come from mihomo's `rules/disable` extension, which sing-box's
/// clash_api does not implement, so the row here stops at what the core will
/// actually tell us — type, payload, outbound, and the cardinality of a
/// rule-set.
class RuleTile extends StatelessWidget {
  const RuleTile({super.key, required this.rule, required this.index});

  final RuleItem rule;

  /// Position in the *unfiltered* list, which is the number the core matches
  /// rules in order of and therefore the number worth showing.
  final int index;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        0,
        AikoDims.pagePadding,
        8,
      ),
      child: CommonCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        semanticLabel: '${rule.type} ${rule.payload} ${rule.proxy}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 34,
                  child: Text(
                    '$index',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    rule.payload.isEmpty ? rule.type : rule.payload,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  RulePill(label: rule.type),
                  RulePill(
                    label: rule.proxy,
                    background: scheme.primaryContainer,
                    foreground: scheme.onPrimaryContainer,
                  ),
                  if (rule.size >= 0)
                    RulePill(
                      label: '${rule.size}',
                      icon: Icons.list_alt_rounded,
                    ),
                ],
              ),
            ),
            if (rule.payload.isEmpty && rule.type.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 34, top: 6),
                child: Text(
                  l10n.t('rules.ruleSet'),
                  style: theme.textTheme.bodySmall?.copyWith(
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

/// One rule provider, with its counts, source and last-update time.
class RuleProviderTile extends StatelessWidget {
  const RuleProviderTile({
    super.key,
    required this.provider,
    required this.updating,
    required this.onUpdate,
  });

  final ProviderInfo provider;

  /// True while this provider's update is in flight.
  final bool updating;

  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = context.l10n;

    final String updated = provider.updatedAt == null
        ? l10n.t('common.never')
        : formatTimestamp(provider.updatedAt!);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        0,
        AikoDims.pagePadding,
        8,
      ),
      child: CommonCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    provider.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      if (provider.ruleCount != null)
                        RulePill(
                          label: '${provider.ruleCount}',
                          icon: Icons.list_alt_rounded,
                          background: scheme.primaryContainer,
                          foreground: scheme.onPrimaryContainer,
                        ),
                      if (provider.behavior != null &&
                          provider.behavior!.isNotEmpty)
                        RulePill(label: provider.behavior!),
                      if (provider.format != null &&
                          provider.format!.isNotEmpty)
                        RulePill(label: provider.format!),
                      if (provider.vehicleType.isNotEmpty)
                        RulePill(
                          label: provider.vehicleType,
                          icon: Icons.cloud_download_outlined,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.t(
                      'profiles.traffic.lastUpdate',
                      args: <String, Object?>{'time': updated},
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: updating
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: l10n.t('common.updater.update'),
                      iconSize: 20,
                      onPressed: onUpdate,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
