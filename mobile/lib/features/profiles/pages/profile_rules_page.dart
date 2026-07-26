/// The rules editor.
///
/// Port of `components/profiles/edit-rules-modal.tsx`. The desktop puts the
/// "add rule" form and the rule list side by side; on a phone they are two
/// tabs of the same screen, because a 1/3-width form on a 400 px viewport is
/// unusable.
///
/// Everything else is the same: the list is the profile's own rules with the
/// override folded in, added rows are green, rows staged for deletion are
/// struck through and can be un-struck, the payload is validated against the
/// rule type before the row can be added, and saving writes only the
/// prepend/append/delete document — the profile itself is never rewritten by
/// this screen.
library;

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_error_text.dart';
import '../data/profiles_providers.dart';
import '../data/rule_editor_model.dart';
import '../data/rule_syntax.dart';
import '../widgets/profile_messages.dart';
import '../widgets/rule_tile.dart';

Future<void> pushProfileRules(BuildContext context, ProfileItem item) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileRulesPage(item: item)),
    );

class ProfileRulesPage extends ConsumerWidget {
  const ProfileRulesPage({super.key, required this.item});

  final ProfileItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final editor = ref.watch(profileRuleEditorProvider(item.id));

    return editor.when(
      loading: () => AikoScaffold(
        title: l10n.t('profiles.editRules.title'),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => AikoScaffold(
        title: l10n.t('profiles.editRules.title'),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.t('common.error.default'),
          message: redactProfileMessage(error.toString()),
        ),
      ),
      data: (initial) => _RulesEditor(item: item, initial: initial),
    );
  }
}

class _RulesEditor extends ConsumerStatefulWidget {
  const _RulesEditor({required this.item, required this.initial});

  final ProfileItem item;
  final RuleEditorState initial;

  @override
  ConsumerState<_RulesEditor> createState() => _RulesEditorState();
}

class _RulesEditorState extends ConsumerState<_RulesEditor>
    with SingleTickerProviderStateMixin {
  late RuleEditorState _state = widget.initial;
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _search = TextEditingController();
  final TextEditingController _payload = TextEditingController();
  final TextEditingController _outbound = TextEditingController(text: 'DIRECT');

  String _type = 'DOMAIN';
  final Set<String> _params = <String>{};
  bool _saving = false;
  bool _dirty = false;

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    _payload.dispose();
    _outbound.dispose();
    super.dispose();
  }

  ClashRule get _draft => ClashRule(
    type: _type,
    payload: _type == kMatchRuleType ? '' : _payload.text.trim(),
    proxy: _outbound.text.trim(),
    params: <String>[
      if (_params.contains(kNoResolveParam)) kNoResolveParam,
      if (_params.contains(kSrcParam)) kSrcParam,
    ],
  );

  bool get _payloadValid =>
      _type == kMatchRuleType ||
      _payload.text.isEmpty ||
      validateRulePayload(_type, _payload.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AikoScaffold(
      titleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(l10n.t('profiles.editRules.title')),
          Text(
            widget.item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving || !_dirty ? null : _save,
          child: Text(l10n.t('common.save')),
        ),
      ],
      bottom: TabBar(
        controller: _tabs,
        tabs: <Widget>[
          Tab(text: l10n.t('profiles.editRules.currentRules')),
          Tab(text: l10n.t('profiles.editRules.addRule')),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_saving) const LinearProgressIndicator(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[_buildList(context), _buildForm(context)],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- list

  Widget _buildList(BuildContext context) {
    final l10n = context.l10n;
    final rows = _state.search(_search.text);

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AikoDims.pagePadding,
            12,
            AikoDims.pagePadding,
            8,
          ),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: l10n.t('profiles.editRules.searchPlaceholder'),
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? EmptyState(
                  icon: Icons.rule_rounded,
                  title: l10n.t(
                    _state.length == 0
                        ? 'profiles.editRules.noRules'
                        : 'profiles.editRules.noMatchingRules',
                  ),
                )
              // The desktop virtualises this list with react-virtuoso; a
              // `ListView.builder` is the same idea and a profile with 50 000
              // rules scrolls without building 50 000 widgets.
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AikoDims.pagePadding,
                    0,
                    AikoDims.pagePadding,
                    AikoDims.fabClearance,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return RuleTile(
                      key: ValueKey<int>(row.index),
                      row: row,
                      total: _state.length,
                      onMoveUp: () => _mutate(_state.moveUp(row.index)),
                      onMoveDown: () => _mutate(_state.moveDown(row.index)),
                      onToggleDelete: () =>
                          _mutate(_state.toggleDelete(row.index)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------- form

  Widget _buildForm(BuildContext context) {
    final l10n = context.l10n;
    final outbounds = ref.watch(profileOutboundNamesProvider(widget.item.id));
    final canAdd = canAddRule(_draft);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        16,
        AikoDims.pagePadding,
        AikoDims.fabClearance,
      ),
      children: <Widget>[
        InputDecorator(
          decoration: InputDecoration(
            labelText: l10n.t('profiles.editRules.ruleType'),
            border: const OutlineInputBorder(),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _type,
              isExpanded: true,
              isDense: true,
              items: <DropdownMenuItem<String>>[
                for (final type in kRuleTypes)
                  DropdownMenuItem<String>(value: type, child: Text(type)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _type = value;
                  // Drop parameters the new type does not accept, exactly as
                  // `handleRuleTypeChange` does.
                  if (!ruleSupportsNoResolve(value)) {
                    _params.remove(kNoResolveParam);
                  }
                  if (!ruleSupportsSrc(value)) _params.remove(kSrcParam);
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _payload,
          enabled: _type != kMatchRuleType,
          onChanged: (_) => setState(() {}),
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.t('profiles.editRules.payload'),
            hintText: ruleExample(_type).isEmpty
                ? l10n.t('profiles.editRules.payloadPlaceholder')
                : ruleExample(_type),
            errorText: _payloadValid
                ? null
                : l10n.t('profiles.editRules.invalidPayload'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _OutboundField(
          controller: _outbound,
          label: l10n.t('profiles.editRules.proxy'),
          hint: l10n.t('profiles.editRules.proxyPlaceholder'),
          options: outbounds.value ?? const <String>[],
          onChanged: () => setState(() {}),
        ),
        if (ruleSupportsNoResolve(_type) || ruleSupportsSrc(_type)) ...<Widget>[
          const SizedBox(height: 8),
          if (ruleSupportsNoResolve(_type))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.t('profiles.editRules.noResolve')),
              value: _params.contains(kNoResolveParam),
              onChanged: (value) => setState(() {
                if (value ?? false) {
                  _params.add(kNoResolveParam);
                } else {
                  _params.remove(kNoResolveParam);
                }
              }),
            ),
          if (ruleSupportsSrc(_type))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.t('profiles.editRules.src')),
              value: _params.contains(kSrcParam),
              onChanged: (value) => setState(() {
                if (value ?? false) {
                  _params.add(kSrcParam);
                } else {
                  _params.remove(kSrcParam);
                }
              }),
            ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: canAdd ? () => _add(asPrepend: true) : null,
          icon: const Icon(Icons.vertical_align_top_rounded, size: 18),
          label: Text(l10n.t('profiles.editRules.addRulePrepend')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: canAdd ? () => _add(asPrepend: false) : null,
          icon: const Icon(Icons.vertical_align_bottom_rounded, size: 18),
          label: Text(l10n.t('profiles.editRules.addRuleAppend')),
        ),
        const SizedBox(height: 28),
        Text(
          l10n.t('profiles.editRules.instructions'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        for (final key in const <String>[
          'profiles.editRules.instructions1',
          'profiles.editRules.instructions2',
          'profiles.editRules.instructions3',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.t(key),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- actions

  void _mutate(RuleEditorState next) {
    setState(() {
      _state = next;
      _dirty = true;
    });
  }

  void _add({required bool asPrepend}) {
    final rule = _draft;
    if (!canAddRule(rule)) {
      showProfileMessage(
        context,
        '${context.l10n.t('profiles.editRules.invalidPayload')}: '
        '${ruleExample(_type)}',
      );
      return;
    }
    _mutate(_state.insert(rule, asPrepend: asPrepend));
    setState(() {
      _payload.clear();
      _type = 'DOMAIN';
      _outbound.text = 'DIRECT';
      _params.clear();
    });
    // Jump back to the list so the new row is visible; adding a rule you cannot
    // see is how you end up adding it twice.
    _tabs.animateTo(0);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(profilesControllerProvider)
          .saveRuleOverlay(widget.item.id, _state.toOverlay());
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
        fallbackKey: 'profiles.editRules.saveError',
      );
    }
  }
}

/// The outbound picker: free text with the profile's own group and proxy names
/// as suggestions, because a rule may legitimately name something the profile
/// does not define yet.
class _OutboundField extends StatelessWidget {
  const _OutboundField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.options,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final List<String> options;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: (_) => onChanged(),
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          enabled: options.isNotEmpty,
          tooltip: label,
          icon: const Icon(Icons.arrow_drop_down_rounded),
          onSelected: (value) {
            controller.text = value;
            onChanged();
          },
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            for (final option in options)
              PopupMenuItem<String>(value: option, child: Text(option)),
          ],
        ),
      ],
    );
  }
}
