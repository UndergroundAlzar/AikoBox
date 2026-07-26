/// Shared building blocks for the Tools section.
///
/// Everything here takes l10n *keys* or already-localised display strings and
/// nothing else — no feature page hard-codes a Material widget's geometry, and
/// no widget in this file reaches for a model type it does not need.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';

// ---------------------------------------------------------------------------
// l10n helpers
// ---------------------------------------------------------------------------

/// Resolves the first key that the active bundle (or the en-US fallback)
/// actually carries.
///
/// This exists so a page can ask for a more specific key than the shipped
/// bundles have yet and still render a sensible string instead of a raw key.
/// The last entry is used unconditionally when nothing matched, so a genuinely
/// missing key is still visible in the UI rather than silently blank.
String trFirst(
  BuildContext context,
  List<String> keys, {
  Map<String, Object?>? args,
}) {
  final AikoL10n l10n = context.l10n;
  for (final String key in keys) {
    if (l10n.has(key)) return l10n.t(key, args: args);
  }
  return l10n.t(keys.last, args: args);
}

/// The string for [key], or null when neither the active locale nor en-US has
/// it. Use for optional text (tooltips, semantic labels) that is better absent
/// than rendered as a dotted key.
String? trOrNull(
  BuildContext context,
  String key, {
  Map<String, Object?>? args,
}) {
  final AikoL10n l10n = context.l10n;
  return l10n.has(key) ? l10n.t(key, args: args) : null;
}

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

/// Shows a transient message. Silently does nothing when [context] has no
/// `ScaffoldMessenger`, which is the case in some widget tests.
void showAikoSnack(BuildContext context, String message, {bool error = false}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final ColorScheme scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? scheme.errorContainer : null,
        showCloseIcon: error,
      ),
    );
}

/// Persists an [AppConfig] mutation, reporting a write failure rather than
/// leaving the switch looking as if it took.
///
/// Returns true when the write landed on disk.
Future<bool> saveAppConfig(
  BuildContext context,
  WidgetRef ref,
  AppConfig Function(AppConfig current) updater,
) async {
  try {
    await ref.read(appConfigProvider.notifier).update(updater);
    return true;
  } catch (_) {
    if (context.mounted) {
      showAikoSnack(
        context,
        context.l10n.t('common.error.updateAppConfigFailed'),
        error: true,
      );
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// A titled group of setting rows, matching the Tools page's section headers.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.isFirst = false,
  });

  /// Already-localised header text. Null renders the group with no header.
  final String? title;

  final List<Widget> children;

  /// Tightens the top gap — set on the first group of a page.
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null) SectionListHeader(title: title!, isFirst: isFirst),
        ...children,
      ],
    );
  }
}

/// Body of a settings sub-page: a scroll view that clears the FAB.
class SettingsBody extends StatelessWidget {
  const SettingsBody({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding:
          padding ?? const EdgeInsets.only(bottom: AikoDims.fabClearance),
      children: children,
    );
  }
}

/// Explanatory paragraph under a header, in `onSurfaceVariant`.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        4,
        AikoDims.pagePadding,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                icon,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// A row with a trailing `Switch`. Tapping anywhere on the row toggles it.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.enabled = true,
    this.tileKey,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final bool live = enabled && onChanged != null;
    return ListTile(
      key: tileKey,
      enabled: live,
      leading: icon == null ? null : Icon(icon, size: 22),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Switch(
        value: value,
        onChanged: live ? onChanged : null,
      ),
      onTap: live ? () => onChanged!(!value) : null,
    );
  }
}

/// A row that opens something and shows the current value on the right.
class SettingsValueTile extends StatelessWidget {
  const SettingsValueTile({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.icon,
    this.onTap,
    this.enabled = true,
    this.showChevron = true,
    this.tileKey,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;

  /// Already-localised current value, rendered right-aligned.
  final String? value;

  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;
  final bool showChevron;
  final Key? tileKey;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool live = enabled && onTap != null;
    final Color? accent = destructive ? scheme.error : null;

    return ListTile(
      key: tileKey,
      enabled: live || onTap == null,
      leading: icon == null ? null : Icon(icon, size: 22),
      iconColor: accent,
      textColor: accent,
      titleTextStyle: accent == null
          ? null
          : (theme.listTileTheme.titleTextStyle ?? theme.textTheme.bodyLarge)
                ?.copyWith(color: accent),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: value == null && !showChevron
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (value != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 168),
                    child: Text(
                      value!,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (showChevron) ...<Widget>[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
      onTap: live ? onTap : null,
    );
  }
}

/// A single-choice row with a leading radio-style check.
class SettingsChoiceTile extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.enabled = true,
    this.tileKey,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: tileKey,
      enabled: enabled && onTap != null,
      selected: selected,
      selectedColor: scheme.primary,
      leading: leading,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected
          ? Icon(Icons.check_rounded, color: scheme.primary)
          : const SizedBox(width: 24),
      onTap: enabled ? onTap : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Chip group
// ---------------------------------------------------------------------------

/// One option of an [AikoChoiceChips] group.
@immutable
class AikoChoiceOption<T> {
  const AikoChoiceOption({required this.value, required this.label, this.icon});

  final T value;

  /// Already-localised label.
  final String label;

  final IconData? icon;
}

/// The outlined selectable chips the visual language uses for small enum
/// choices — theme mode, outbound mode, split-tunnel mode.
class AikoChoiceChips<T> extends StatelessWidget {
  const AikoChoiceChips({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<AikoChoiceOption<T>> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final bool live = enabled && onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AikoDims.pagePadding,
        vertical: 4,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final AikoChoiceOption<T> option in options)
            ChoiceChip(
              key: ValueKey<String>('aiko-chip-${option.value}'),
              label: Text(option.label),
              avatar: option.icon == null ? null : Icon(option.icon, size: 18),
              selected: option.value == value,
              onSelected: live
                  ? (bool picked) {
                      if (picked) onChanged!(option.value);
                    }
                  : null,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

/// Modal single-choice picker. Returns null when dismissed.
Future<T?> showAikoOptionSheet<T>(
  BuildContext context, {
  required String title,
  required List<AikoChoiceOption<T>> options,
  required T selected,
  Map<T, String>? descriptions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final ThemeData theme = Theme.of(sheetContext);
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final AikoChoiceOption<T> option in options)
                SettingsChoiceTile(
                  tileKey: ValueKey<String>('aiko-option-${option.value}'),
                  title: option.label,
                  subtitle: descriptions?[option.value],
                  leading: option.icon == null
                      ? null
                      : Icon(option.icon, size: 22),
                  selected: option.value == selected,
                  onTap: () => Navigator.of(sheetContext).pop(option.value),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Modal single-line text editor. Returns the new value, or null when the user
/// cancelled. [validate] gates the confirm button.
Future<String?> showAikoTextSheet(
  BuildContext context, {
  required String title,
  required String initialValue,
  String? hintText,
  String? helperText,
  TextInputType keyboardType = TextInputType.text,
  List<TextInputFormatter> inputFormatters = const <TextInputFormatter>[],
  bool Function(String value)? validate,
}) {
  final AikoL10n l10n = context.l10n;
  final String cancelLabel = l10n.t('common.cancel');
  final String saveLabel = l10n.t('common.save');

  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _TextSheet(
      title: title,
      initialValue: initialValue,
      hintText: hintText,
      helperText: helperText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validate: validate,
      cancelLabel: cancelLabel,
      saveLabel: saveLabel,
    ),
  );
}

class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.title,
    required this.initialValue,
    required this.hintText,
    required this.helperText,
    required this.keyboardType,
    required this.inputFormatters,
    required this.validate,
    required this.cancelLabel,
    required this.saveLabel,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final String? helperText;
  final TextInputType keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool Function(String value)? validate;
  final String cancelLabel;
  final String saveLabel;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _valid => widget.validate?.call(_controller.text) ?? true;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('aiko-text-sheet-field'),
                controller: _controller,
                autofocus: true,
                keyboardType: widget.keyboardType,
                inputFormatters: widget.inputFormatters,
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  helperText: widget.helperText,
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (String value) {
                  if (_valid) Navigator.of(context).pop(value);
                },
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(widget.cancelLabel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('aiko-text-sheet-save'),
                      onPressed: _valid
                          ? () => Navigator.of(context).pop(_controller.text)
                          : null,
                      child: Text(widget.saveLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal integer editor with a hard [min]/[max] range. Returns null when the
/// user cancelled.
Future<int?> showAikoNumberSheet(
  BuildContext context, {
  required String title,
  required int initialValue,
  required int min,
  required int max,
  String? hintText,
  String? helperText,
}) async {
  final String? raw = await showAikoTextSheet(
    context,
    title: title,
    initialValue: '$initialValue',
    hintText: hintText,
    helperText: helperText,
    keyboardType: TextInputType.number,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ],
    validate: (String value) {
      final int? parsed = int.tryParse(value.trim());
      return parsed != null && parsed >= min && parsed <= max;
    },
  );
  if (raw == null) return null;
  final int? parsed = int.tryParse(raw.trim());
  if (parsed == null) return null;
  return parsed.clamp(min, max);
}
