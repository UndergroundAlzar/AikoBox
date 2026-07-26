/// The rules page.
///
/// Port of `src/renderer/src/pages/rules.tsx`, which is just a filtered list,
/// plus the rule-provider list the desktop keeps on its Resources page. On a
/// phone those two belong together: a rule that reads `RULE-SET,foo,PROXY` is
/// only half an answer without knowing when `foo` was last fetched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'rule_tile.dart';
import 'rules_controller.dart';

class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});

  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);
  final TextEditingController _rulesSearch = TextEditingController();
  final TextEditingController _providersSearch = TextEditingController();

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    _rulesSearch.dispose();
    _providersSearch.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  bool get _onProviders => _tabs.index == 1;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    final AsyncValue<List<RuleItem>> rules = ref.watch(filteredRulesProvider);
    final AsyncValue<List<ProviderInfo>> providers = ref.watch(
      filteredRuleProvidersProvider,
    );
    final Set<String> updating = ref.watch(ruleProviderUpdatesProvider);

    return AikoScaffold(
      title: l10n.t('rules.title'),
      actions: <Widget>[
        if (_onProviders)
          IconButton(
            tooltip: l10n.t('resources.ruleProviders.updateAll'),
            onPressed:
                updating.isNotEmpty || (providers.value?.isEmpty ?? true)
                ? null
                : () => _updateAll(providers.value!),
            icon: const Icon(Icons.cloud_sync_outlined),
          ),
        IconButton(
          tooltip: l10n.t('common.refresh'),
          onPressed: () {
            ref
              ..invalidate(rulesProvider)
              ..invalidate(ruleProvidersProvider);
          },
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(104),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AikoDims.pagePadding,
                0,
                AikoDims.pagePadding,
                8,
              ),
              child: _onProviders
                  ? _SearchField(
                      key: const ValueKey<String>('rules.providers.search'),
                      controller: _providersSearch,
                      hint: l10n.t('resources.ruleProviders.filter'),
                      onChanged: ref
                          .read(ruleProvidersQueryProvider.notifier)
                          .set,
                    )
                  : _SearchField(
                      key: const ValueKey<String>('rules.search'),
                      controller: _rulesSearch,
                      hint: l10n.t('rules.filter'),
                      onChanged: ref.read(rulesQueryProvider.notifier).set,
                    ),
            ),
            SizedBox(
              height: 48,
              child: TabBar(
                controller: _tabs,
                tabs: <Widget>[
                  Tab(text: l10n.t('rules.title')),
                  Tab(text: l10n.t('resources.ruleProviders.title')),
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _AsyncSection<List<RuleItem>>(
            value: rules,
            running: running,
            emptyTitle: l10n.t('rules.empty'),
            emptyIcon: Icons.rule_folder_outlined,
            isEmpty: (List<RuleItem> items) => items.isEmpty,
            onRetry: () => ref.invalidate(rulesProvider),
            builder: (List<RuleItem> items) => SuperListView.builder(
              padding: const EdgeInsets.only(
                top: 8,
                bottom: AikoDims.fabClearance,
              ),
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) =>
                  RuleTile(rule: items[index], index: index),
            ),
          ),
          _AsyncSection<List<ProviderInfo>>(
            value: providers,
            running: running,
            emptyTitle: l10n.t('common.emptyState'),
            emptyIcon: Icons.cloud_off_outlined,
            isEmpty: (List<ProviderInfo> items) => items.isEmpty,
            onRetry: () => ref.invalidate(ruleProvidersProvider),
            builder: (List<ProviderInfo> items) => SuperListView.builder(
              padding: const EdgeInsets.only(
                top: 8,
                bottom: AikoDims.fabClearance,
              ),
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) {
                final ProviderInfo provider = items[index];
                return RuleProviderTile(
                  provider: provider,
                  updating: updating.contains(provider.name),
                  onUpdate: () => _updateOne(provider.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateOne(String name) async {
    final AikoL10n l10n = context.l10n;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    try {
      await ref.read(ruleProviderUpdatesProvider.notifier).update(name);
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(l10n.t(failureMessageKey(error))),
        ),
      );
    }
  }

  Future<void> _updateAll(List<ProviderInfo> providers) async {
    final AikoL10n l10n = context.l10n;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final int failed = await ref
        .read(ruleProviderUpdatesProvider.notifier)
        .updateAll(
          <String>[for (final ProviderInfo item in providers) item.name],
        );
    // N5: an update that partly failed says so rather than looking clean.
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          failed == 0
              ? l10n.t(
                  'profiles.notification.updateAllSuccess',
                  args: <String, Object?>{'count': providers.length},
                )
              : l10n.t(
                  'profiles.notification.updateAllPartial',
                  args: <String, Object?>{
                    'succeeded': providers.length - failed,
                    'failed': failed,
                  },
                ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          hintText: hint,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

/// Renders one of the four states an `AsyncValue`-backed list can be in.
class _AsyncSection<T> extends StatelessWidget {
  const _AsyncSection({
    required this.value,
    required this.running,
    required this.emptyTitle,
    required this.emptyIcon,
    required this.isEmpty,
    required this.builder,
    required this.onRetry,
  });

  final AsyncValue<T> value;

  /// When the core is stopped an empty list is expected, not a problem, and
  /// gets the "core is not running" copy instead of "nothing here".
  final bool running;

  final String emptyTitle;
  final IconData emptyIcon;
  final bool Function(T value) isEmpty;
  final Widget Function(T value) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;

    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: l10n.t(failureMessageKey(error)),
        action: FilledButton.tonal(
          onPressed: onRetry,
          child: Text(l10n.t('common.retry')),
        ),
      ),
      data: (T data) => isEmpty(data)
          ? EmptyState(
              icon: emptyIcon,
              title: running
                  ? emptyTitle
                  : l10n.t('dashboard.core.notRunning'),
            )
          : builder(data),
    );
  }
}
