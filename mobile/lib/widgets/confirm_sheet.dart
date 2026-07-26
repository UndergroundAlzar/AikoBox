import 'package:flutter/material.dart';

/// Asks the user to confirm something, as a modal bottom sheet.
///
/// Returns `true` only when the confirm button was pressed; dismissing the
/// sheet any other way returns `false`. Every label is an already-localised
/// display string supplied by the caller.
Future<bool> showAikoConfirmSheet(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String cancelLabel,
  String? message,
  IconData? icon,
  bool destructive = false,
  bool dismissible = true,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    builder: (sheetContext) => ConfirmSheet(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      icon: icon,
      destructive: destructive,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onCancel: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return result ?? false;
}

/// The body of [showAikoConfirmSheet], exposed so it can be embedded or tested
/// without a navigator.
class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({
    super.key,
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.onConfirm,
    required this.onCancel,
    this.message,
    this.icon,
    this.destructive = false,
  });

  final String title;
  final String? message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData? icon;

  /// Paints the glyph and the confirm button in `colorScheme.error`.
  final bool destructive;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Color accent = destructive ? scheme.error : scheme.primary;
    final Color accentContainer = destructive
        ? scheme.errorContainer
        : scheme.primaryContainer;
    final Color onAccent = destructive ? scheme.onError : scheme.onPrimary;

    return SafeArea(
      top: false,
      // A long message in a short landscape window would otherwise overflow the
      // sheet; scrolling is preferable to a clipped confirm button.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: ShapeDecoration(
                    color: accentContainer,
                    shape: const CircleBorder(),
                  ),
                  child: Icon(icon, size: 28, color: accent),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    child: Text(
                      cancelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onConfirm,
                    style: destructive
                        ? FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: onAccent,
                          )
                        : null,
                    child: Text(
                      confirmLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
