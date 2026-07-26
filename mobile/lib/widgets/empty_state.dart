import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// "Nothing here yet" placeholder.
///
/// [title], [message] and any label inside [action] are already-localised
/// display strings.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  final IconData icon;
  final String title;

  /// One or two lines explaining what to do about it.
  final String? message;

  /// A single call-to-action button, usually a `FilledButton.tonal`.
  final Widget? action;

  /// Smaller glyph and tighter spacing, for use inside a card rather than a
  /// whole page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final double glyphBox = compact ? 48 : 72;
    final double glyphSize = compact ? 24 : 34;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 32,
          vertical: compact ? 12 : 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: glyphBox,
              height: glyphBox,
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerHighest,
                shape: const CircleBorder(),
              ),
              child: Icon(
                icon,
                size: glyphSize,
                color: scheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: compact ? 12 : 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style:
                  (compact
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.titleMedium)
                      ?.copyWith(color: scheme.onSurface),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              SizedBox(height: compact ? 12 : AikoDims.cardPadding),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
