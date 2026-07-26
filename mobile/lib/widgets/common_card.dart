import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The card primitive every AikoBox screen is built from.
///
/// Deliberately **not** a Material [Card]: no shadow, no elevation tint, no
/// filled surface. A card here is a 1 px `outlineVariant` hairline around a
/// transparent fill with a [AikoDims.cardRadius] corner radius, exactly like
/// FlClash's `CommonCard`. Selection is expressed with colour, never with a
/// thicker border, so nothing reflows when a card is picked.
///
/// Pass [icon] and/or [label] to get the standard header row: an 18 px
/// primary-tinted icon and a `titleSmall` label in `onSurfaceVariant`. The
/// header sits above [child], which is padded by [padding].
///
/// Strings are already-localised display text — this widget never touches
/// `l10n` itself.
class CommonCard extends StatelessWidget {
  const CommonCard({
    super.key,
    required this.child,
    this.icon,
    this.label,
    this.headerActions = const <Widget>[],
    this.onTap,
    this.onLongPress,
    this.padding,
    this.isSelected = false,
    this.isError = false,
    this.selectedColor,
    this.selectedForegroundColor,
    this.selectedOverlay,
    this.borderColor,
    this.backgroundColor,
    this.radius = AikoDims.cardRadius,
    this.semanticLabel,
  });

  /// Card body. Laid out below the header when there is one.
  final Widget child;

  /// Header icon, drawn at [AikoDims.cardHeaderIconSize] in `colorScheme.primary`.
  final IconData? icon;

  /// Header label, already localised. Rendered in `titleSmall`.
  final String? label;

  /// Trailing widgets in the header row (icon buttons, switches, …).
  final List<Widget> headerActions;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Padding around [child]. Defaults to 16 px on all sides, minus the top when
  /// a header is present (the header already supplies that gap).
  final EdgeInsetsGeometry? padding;

  /// Draws the card in its selected state: [selectedColor] fill and a `primary`
  /// hairline.
  final bool isSelected;

  /// Draws the hairline — and the header icon — in `colorScheme.error`.
  final bool isError;

  /// Fill used when [isSelected]. Defaults to `colorScheme.primaryContainer`.
  /// Override [selectedForegroundColor] alongside it or the header will be
  /// unreadable.
  final Color? selectedColor;

  /// Header foreground used when [isSelected].
  /// Defaults to `colorScheme.onPrimaryContainer`.
  final Color? selectedForegroundColor;

  /// Stacked over the card via `Positioned.fill` while [isSelected] — the check
  /// mark on a seed-colour swatch, for instance. Ignores pointers.
  final Widget? selectedOverlay;

  /// Overrides the hairline colour outright.
  final Color? borderColor;

  /// Overrides the unselected fill. Cards are transparent by default.
  final Color? backgroundColor;

  final double radius;

  final String? semanticLabel;

  bool get _hasHeader =>
      icon != null || label != null || headerActions.isNotEmpty;

  bool get _isInteractive => onTap != null || onLongPress != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    final Color resolvedBorder =
        borderColor ??
        (isError
            ? scheme.error
            : isSelected
            ? scheme.primary
            : scheme.outlineVariant);

    final Color resolvedFill = isSelected
        ? (selectedColor ?? scheme.primaryContainer)
        : (backgroundColor ?? Colors.transparent);

    final Color headerForeground = isError
        ? scheme.error
        : isSelected
        ? (selectedForegroundColor ?? scheme.onPrimaryContainer)
        : scheme.onSurfaceVariant;

    final Color headerIconColor = isError
        ? scheme.error
        : isSelected
        ? (selectedForegroundColor ?? scheme.onPrimaryContainer)
        : scheme.primary;

    Widget content = Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            AikoDims.cardPadding,
            _hasHeader ? 0 : AikoDims.cardPadding,
            AikoDims.cardPadding,
            AikoDims.cardPadding,
          ),
      child: child,
    );

    if (_hasHeader) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CardHeader(
            icon: icon,
            label: label,
            actions: headerActions,
            foreground: headerForeground,
            iconColor: headerIconColor,
          ),
          content,
        ],
      );
    }

    Widget result = AnimatedContainer(
      duration: AikoDims.midMotion,
      curve: Curves.easeOut,
      decoration: ShapeDecoration(
        color: resolvedFill,
        shape: shape.copyWith(
          side: BorderSide(
            color: resolvedBorder,
            width: AikoDims.cardBorderWidth,
          ),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: _isInteractive
            ? InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                customBorder: shape,
                child: content,
              )
            : content,
      ),
    );

    if (isSelected && selectedOverlay != null) {
      result = Stack(
        children: <Widget>[
          result,
          Positioned.fill(child: IgnorePointer(child: selectedOverlay!)),
        ],
      );
    }

    if (semanticLabel != null) {
      result = Semantics(
        container: true,
        selected: isSelected,
        button: _isInteractive,
        label: semanticLabel,
        child: result,
      );
    }

    return result;
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({
    required this.icon,
    required this.label,
    required this.actions,
    required this.foreground,
    required this.iconColor,
  });

  final IconData? icon;
  final String? label;
  final List<Widget> actions;
  final Color foreground;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      // The right edge tightens when there are actions so icon buttons keep
      // their 48 px hit target without pushing the card wider.
      padding: EdgeInsets.fromLTRB(
        AikoDims.cardPadding,
        14,
        actions.isEmpty ? AikoDims.cardPadding : 8,
        10,
      ),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: AikoDims.cardHeaderIconSize, color: iconColor),
            const SizedBox(width: AikoDims.cardHeaderGap),
          ],
          if (label != null)
            Expanded(
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(color: foreground),
              ),
            )
          else
            const Spacer(),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            IconTheme.merge(
              data: IconThemeData(color: foreground, size: 20),
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ],
        ],
      ),
    );
  }
}
