/// The shared shell for the two YAML editors.
///
/// Port of `components/profiles/edit-file-modal.tsx` and
/// `components/override/edit-file-modal.tsx`, which are the same modal twice
/// over. The desktop hosts Monaco; this hosts [YamlSourceField] and adds the
/// two things Monaco gave the desktop for free:
///
///  * **A document is parsed before it is written.** A profile that does not
///    parse would fail at core start, several screens away from the typo that
///    caused it. Saving is refused here instead, with the parser's line and
///    column pointed at in the gutter.
///  * **Leaving with unsaved edits asks first.**
library;

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';

import '../data/yaml_document.dart';
import '../widgets/profile_messages.dart';
import '../widgets/yaml_source_field.dart';

/// Writes the edited document. Throwing reports the failure and keeps the page
/// open with the user's text intact.
typedef YamlSaveCallback = Future<void> Function(String text);

class YamlEditorPage extends StatefulWidget {
  const YamlEditorPage({
    super.key,
    required this.title,
    required this.initialText,
    required this.onSave,
    this.subtitle,
    this.notice,
    this.onReset,
    this.resetLabel,
  });

  /// Already-localised page title.
  final String title;

  /// Already-localised line under the title — the profile's name, usually.
  final String? subtitle;

  /// Already-localised advisory shown above the editor.
  final String? notice;

  final String initialText;
  final YamlSaveCallback onSave;

  /// Offered in the overflow menu when present — "discard this override".
  final Future<void> Function()? onReset;
  final String? resetLabel;

  @override
  State<YamlEditorPage> createState() => _YamlEditorPageState();
}

class _YamlEditorPageState extends State<YamlEditorPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  YamlDocumentException? _error;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    final dirty = _controller.text != widget.initialText;
    if (dirty != _dirty || _error != null) {
      setState(() {
        _dirty = dirty;
        // The marker is from the last failed save; the moment the text moves it
        // is stale, and a gutter pointing at the wrong line is worse than none.
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;
        // "Save?" with [Discard] [Save]. Deliberately composed from strings the
        // locale files already ship — a key that is missing renders as the key
        // itself, which is a worse outcome than a terse prompt.
        final save = await showAikoConfirmSheet(
          context,
          title: l10n.t('common.save'),
          confirmLabel: l10n.t('common.save'),
          cancelLabel: l10n.t('common.dismiss'),
          icon: Icons.save_outlined,
        );
        if (!context.mounted) return;
        if (save) {
          await _save();
        } else {
          setState(() => _dirty = false);
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: AikoScaffold(
        titleWidget: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.title),
            if (widget.subtitle != null)
              Text(
                widget.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: <Widget>[
          if (widget.onReset != null)
            IconButton(
              tooltip: widget.resetLabel ?? l10n.t('common.reset'),
              onPressed: _saving ? null : _reset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          TextButton(
            onPressed: _saving || !_dirty ? null : _save,
            child: Text(l10n.t('common.save')),
          ),
        ],
        body: Padding(
          padding: const EdgeInsets.fromLTRB(
            AikoDims.pagePadding,
            0,
            AikoDims.pagePadding,
            AikoDims.pagePadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_saving) const LinearProgressIndicator(),
              if (widget.notice != null) ...<Widget>[
                _Banner(
                  icon: Icons.info_outline_rounded,
                  text: widget.notice!,
                  isError: false,
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...<Widget>[
                _Banner(
                  icon: Icons.error_outline_rounded,
                  text: _error!.hasPosition
                      ? '${_error!.line}:${_error!.column} — ${_error!.message}'
                      : _error!.message,
                  isError: true,
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: YamlSourceField(
                  controller: _controller,
                  errorLine: _error?.line,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final failure = validateYamlMap(_controller.text);
    if (failure != null) {
      setState(() => _error = failure);
      showProfileError(
        context,
        failure,
        fallbackKey: 'common.error.saveProfileConfigFailed',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      showProfileMessage(context, context.l10n.t('common.saved'));
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showProfileError(
        context,
        error,
        fallbackKey: 'common.error.saveProfileConfigFailed',
      );
    }
  }

  Future<void> _reset() async {
    final l10n = context.l10n;
    final confirmed = await showAikoConfirmSheet(
      context,
      title: widget.resetLabel ?? l10n.t('common.reset'),
      message: l10n.t('profiles.editFile.notice'),
      confirmLabel: l10n.t('common.confirm'),
      cancelLabel: l10n.t('common.cancel'),
      icon: Icons.restart_alt_rounded,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      await widget.onReset!();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showProfileError(context, error);
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.isError,
  });

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Color background = isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final Color foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
