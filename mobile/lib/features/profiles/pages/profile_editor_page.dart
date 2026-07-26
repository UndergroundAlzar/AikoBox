/// Import a subscription, or edit an existing profile's information.
///
/// Port of `src/renderer/src/components/profiles/edit-info-modal.tsx`, which is
/// one component in two modes for the same reason: importing and editing take
/// the same set of fields, and keeping them in one place is what stops the two
/// forms drifting apart.
///
/// Two fields the desktop has are deliberately absent, because wiring a control
/// that does nothing is worse than not offering it:
///
///  * **Use proxy to update.** The desktop fetches a subscription through its
///    own mixed-port inbound. The Dart core does not implement that, on purpose
///    — routing a subscription fetch through the tunnel the subscription is
///    about to reconfigure is exactly the kind of surprise N5 exists to
///    prevent, and the mixed port is not reliably up during an import anyway.
///  * **Age secret key.** Age-encrypted subscriptions are not ported; there is
///    no age implementation in `pubspec.yaml`.
///
/// The auth token is real and is kept in the Android keystore — see
/// `ProfileSecretStore`.
library;

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profiles_providers.dart';
import '../data/update_schedule.dart';
import '../widgets/profile_messages.dart';

/// Opens the editor for a new subscription. Returns true when one was imported.
Future<bool> pushImportSubscription(BuildContext context) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const ProfileEditorPage.import(),
      ),
    ) ??
    false;

/// Opens the editor for an existing profile.
Future<void> pushProfileEditor(BuildContext context, ProfileItem item) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileEditorPage.edit(item)),
    );

class ProfileEditorPage extends ConsumerStatefulWidget {
  const ProfileEditorPage.import({super.key}) : item = null;

  const ProfileEditorPage.edit(ProfileItem this.item, {super.key});

  /// Null in import mode.
  final ProfileItem? item;

  bool get isImport => item == null;

  @override
  ConsumerState<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends ConsumerState<ProfileEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _authToken;
  late final TextEditingController _userAgent;
  late final TextEditingController _interval;
  late final TextEditingController _timeout;

  bool _autoUpdate = false;
  bool _fixedInterval = false;
  bool _obscureToken = true;
  bool _saving = false;
  bool _tokenLoaded = false;
  String _initialToken = '';

  bool get _isRemote => widget.isImport || (widget.item?.isRemote ?? false);

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name ?? '');
    _url = TextEditingController(text: item?.url ?? '');
    _authToken = TextEditingController();
    _userAgent = TextEditingController(text: item?.userAgent ?? '');
    _interval = TextEditingController(
      text: item?.interval?.toString() ?? '',
    );
    _timeout = TextEditingController(
      text: item?.updateTimeout?.toString() ?? '',
    );
    _autoUpdate = item?.autoUpdate ?? false;
    if (item != null) _loadStoredExtras(item.id);
  }

  /// Pulls the stored token and cron out of the keystore and the sidecar once
  /// the page is up. Both are off the profile index, so neither is on [item].
  void _loadStoredExtras(String id) {
    Future<void>(() async {
      final token = await ref.read(profileSecretStoreProvider).readAuthToken(id);
      final overlay = await ref.read(profileOverlayProvider(id).future);
      if (!mounted) return;
      setState(() {
        _tokenLoaded = true;
        _initialToken = token ?? '';
        _authToken.text = _initialToken;
        _fixedInterval = overlay.overlay.schedule.fixedInterval;
        final cron = overlay.overlay.schedule.cron;
        if (cron != null && _interval.text.isEmpty) _interval.text = cron;
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _authToken.dispose();
    _userAgent.dispose();
    _interval.dispose();
    _timeout.dispose();
    super.dispose();
  }

  UpdateSchedule get _schedule => UpdateSchedule.parse(_interval.text);

  bool get _canSave {
    if (_saving) return false;
    if (_isRemote && _url.text.trim().isEmpty) return false;
    if (_autoUpdate && !_schedule.isValid) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AikoScaffold(
      title: l10n.t(
        widget.isImport ? 'profiles.importFromUrl' : 'profiles.editInfo.title',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _canSave ? _save : null,
          child: Text(
            l10n.t(widget.isImport ? 'profiles.import' : 'common.save'),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AikoDims.pagePadding,
          8,
          AikoDims.pagePadding,
          AikoDims.fabClearance,
        ),
        children: <Widget>[
          if (_saving) ...<Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
          ],
          _Field(
            controller: _name,
            label: l10n.t('profiles.editInfo.name'),
            hint: l10n.t('profiles.newProfile'),
            onChanged: (_) => setState(() {}),
          ),
          if (_isRemote) ...<Widget>[
            const SizedBox(height: 16),
            _Field(
              controller: _url,
              label: l10n.t('profiles.editInfo.url'),
              hint: l10n.t('profiles.input.placeholder'),
              keyboardType: TextInputType.url,
              autofocus: widget.isImport,
              onChanged: (_) => setState(() {}),
              trailing: IconButton(
                tooltip: l10n.t('profiles.importFromClipboard'),
                icon: const Icon(Icons.content_paste_rounded, size: 20),
                onPressed: _pasteUrl,
              ),
            ),
            const SizedBox(height: 16),
            _Field(
              controller: _authToken,
              label: l10n.t('profiles.editInfo.authToken'),
              hint: l10n.t('profiles.editInfo.authTokenPlaceholder'),
              obscure: _obscureToken,
              enabled: widget.isImport || _tokenLoaded,
              trailing: IconButton(
                icon: Icon(
                  _obscureToken
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => _obscureToken = !_obscureToken),
              ),
            ),
            const SizedBox(height: 16),
            _Field(
              controller: _userAgent,
              label: l10n.t('profiles.editInfo.userAgent'),
              hint: l10n.t('profiles.editInfo.userAgentPlaceholder'),
            ),
            const SizedBox(height: 16),
            _Field(
              controller: _timeout,
              label: l10n.t('profiles.editInfo.updateTimeout'),
              hint: l10n.t('profiles.editInfo.updateTimeoutPlaceholder'),
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              suffixText: l10n.t('common.seconds'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.t('profiles.editInfo.autoUpdate')),
              value: _autoUpdate,
              onChanged: (value) => setState(() => _autoUpdate = value),
            ),
            if (_autoUpdate) ...<Widget>[
              _Field(
                controller: _interval,
                label: l10n.t('profiles.editInfo.interval'),
                hint: l10n.t('profiles.editInfo.intervalPlaceholder'),
                errorText: _schedule.isValid
                    ? null
                    : l10n.t('profiles.editInfo.intervalInvalid'),
                inputFormatters: <TextInputFormatter>[
                  // The desktop restricts the field to the characters a number
                  // or a cron expression can contain.
                  FilteringTextInputFormatter.allow(RegExp(r'[\d\s*\-,/]')),
                ],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.t(_intervalHintKey()),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _schedule.isValid
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.t('profiles.editInfo.fixedInterval')),
                value: _fixedInterval,
                onChanged: (value) => setState(() => _fixedInterval = value),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _intervalHintKey() => switch (_schedule) {
    UpdateScheduleMinutes() => 'profiles.editInfo.intervalMinutes',
    UpdateScheduleCron() => 'profiles.editInfo.intervalCron',
    _ => 'profiles.editInfo.intervalHint',
  };

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _url.text = text);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final controller = ref.read(profilesControllerProvider);
    final schedule = _schedule;
    final int? minutes = schedule is UpdateScheduleMinutes
        ? schedule.minutes
        : null;
    final String? cron = schedule is UpdateScheduleCron
        ? schedule.expression
        : null;
    final int? timeout = int.tryParse(_timeout.text.trim());
    final token = _authToken.text.trim();

    try {
      if (widget.isImport) {
        await controller.importRemote(
          url: _url.text,
          name: _name.text,
          authToken: token.isEmpty ? null : token,
          userAgent: _userAgent.text.trim().isEmpty
              ? null
              : _userAgent.text.trim(),
          autoUpdate: _autoUpdate,
          intervalMinutes: _autoUpdate ? minutes : null,
          cron: _autoUpdate ? cron : null,
          fixedInterval: _autoUpdate && _fixedInterval,
          updateTimeoutSeconds: timeout,
        );
      } else {
        await controller.saveInfo(
          widget.item!.id,
          name: _name.text,
          url: _url.text,
          userAgent: _userAgent.text,
          autoUpdate: _autoUpdate,
          intervalMinutes: _autoUpdate ? minutes : null,
          cron: _autoUpdate ? cron : null,
          fixedInterval: _autoUpdate && _fixedInterval,
          updateTimeoutSeconds: timeout,
          authToken: token,
          clearAuthToken: token.isEmpty && _initialToken.isNotEmpty,
        );
      }
      if (!mounted) return;
      showProfileMessage(
        context,
        context.l10n.t(
          widget.isImport
              ? 'profiles.notification.importSuccess'
              : 'common.saved',
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showProfileError(
        context,
        error,
        fallbackKey: widget.isImport
            ? 'profiles.error.importFailed'
            : 'common.error.updateProfileFailed',
      );
    }
  }
}

/// One labelled text field, styled the same way across the form.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.suffixText,
    this.trailing,
    this.obscure = false,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final String? suffixText;
  final Widget? trailing;
  final bool obscure;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        suffixText: suffixText,
        suffixIcon: trailing,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
