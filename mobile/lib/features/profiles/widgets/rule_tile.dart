/// One row of the rules editor.
///
/// Port of `RuleListItem` in
/// `src/renderer/src/components/profiles/edit-rules-modal.tsx`: a type chip,
/// the payload, the outbound, extra-parameter chips, and move/remove controls.
/// Added rows get a green wash, rows marked for deletion get a red one and a
/// strike-through, and the delete button becomes an undo.
library;

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:flutter/material.dart';

import '../data/rule_editor_model.dart';

class RuleTile extends StatelessWidget {
  const RuleTile({
    super.key,
    required this.row,
    required this.total,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onToggleDelete,
  });

  final RuleRow row;

  /// Total number of rows, so the last one cannot move down.
  final int total;

  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onToggleDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = AikoStatusColors.of(context);
    final rule = row.rule;

    final Color background = switch (row.state) {
      RuleRowState.deleted => status.badContainer,
      RuleRowState.added => status.goodContainer,
      RuleRowState.original => Colors.transparent,
    };
    final Color foreground = switch (row.state) {
      RuleRowState.deleted => status.onBadContainer,
      RuleRowState.added => status.onGoodContainer,
      RuleRowState.original => scheme.onSurface,
    };
    final TextDecoration? decoration = row.isDeleted
        ? TextDecoration.lineThrough
        : null;

    final String primary = rule.isMatch ? rule.proxy : rule.payload;
    final String? secondary = rule.isMatch || rule.proxy.isEmpty
        ? null
        : rule.proxy;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: row.state == RuleRowState.original
                ? scheme.outlineVariant
                : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _Chip(label: rule.type, color: foreground),
                    if (rule.offset != null)
                      _Chip(label: '#${rule.offset}', color: foreground),
                    for (final param in rule.params)
                      _Chip(label: param, color: scheme.tertiary),
                  ],
                ),
                if (primary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    primary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w500,
                      decoration: decoration,
                    ),
                  ),
                ],
                if (secondary != null)
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground.withValues(alpha: 0.75),
                      decoration: decoration,
                    ),
                  ),
              ],
            ),
          ),
          // No tooltips on the arrows: the locale files have no "move up" /
          // "move down" string, and `common.prev` / `common.next` mean
          // "previous step" / "next step" in a wizard — wrong words on a
          // button that reorders a list. The glyphs carry the meaning.
          IconButton(
            onPressed: row.index == 0 || row.isDeleted ? null : onMoveUp,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_upward_rounded, size: 18),
          ),
          IconButton(
            onPressed: row.index >= total - 1 || row.isDeleted
                ? null
                : onMoveDown,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_downward_rounded, size: 18),
          ),
          IconButton(
            onPressed: onToggleDelete,
            tooltip: l10n.t(row.isDeleted ? 'common.reset' : 'common.delete'),
            visualDensity: VisualDensity.compact,
            color: row.isDeleted ? status.good : scheme.error,
            icon: Icon(
              row.isDeleted ? Icons.undo_rounded : Icons.delete_outline_rounded,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
