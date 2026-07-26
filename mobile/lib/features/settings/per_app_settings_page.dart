/// Per-app proxy (split tunnelling).
///
/// Android has no desktop equivalent, so this is designed straight against the
/// two knobs `VpnService.Builder` actually offers: `addAllowedApplication` and
/// `addDisallowedApplication`. They are mutually exclusive, which is why the
/// mode is a three-way choice and not two independent lists —
/// `AppConfig.includePackages` / `excludePackages` derive from it and
/// `AikoCoreController` passes exactly one of them to `start()`.
///
/// Nothing here touches a running tunnel: Android fixes the app list when the
/// interface is established, so a change applies on the next start. That is
/// stated in the UI rather than pretended away.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import 'app_info.dart';
import 'settings_controls.dart';

const String kPerAppSettingsRoute = '/settings/per-app';

/// Row ordering of the app list.
enum PerAppSort { name, selectedFirst }

class PerAppSettingsPage extends ConsumerStatefulWidget {
  const PerAppSettingsPage({super.key});

  @override
  ConsumerState<PerAppSettingsPage> createState() => _PerAppSettingsPageState();
}

class _PerAppSettingsPageState extends ConsumerState<PerAppSettingsPage> {
  final TextEditingController _search = TextEditingController();

  Set<String> _selected = <String>{};
  bool _showSystem = false;
  PerAppSort _sort = PerAppSort.name;

  @override
  void initState() {
    super.initState();
    _selected = ref.read(appConfigProvider).splitTunnelPackages.toSet();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _persist(Set<String> next) async {
    // Optimistic: the checkbox flips now and the file write follows. If the
    // write fails the selection goes back, because a tick that did not reach
    // disk is worse than no tick at all.
    final Set<String> previous = _selected;
    setState(() => _selected = next);
    final List<String> ordered = next.toList()..sort();
    final bool saved = await saveAppConfig(
      context,
      ref,
      (AppConfig current) => current.copyWith(splitTunnelPackages: ordered),
    );
    if (!saved && mounted) setState(() => _selected = previous);
  }

  Future<void> _setMode(SplitTunnelMode mode) => saveAppConfig(
    context,
    ref,
    (AppConfig current) => current.copyWith(splitTunnelMode: mode),
  );

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final SplitTunnelMode mode = ref.watch(
      appConfigProvider.select((AppConfig c) => c.splitTunnelMode),
    );

    // The config hydrates from disk one frame after the first build, and a
    // restored backup can replace it at any time. Adopt whatever the store says
    // unless it already matches what this page holds.
    ref.listen<List<String>>(
      appConfigProvider.select((AppConfig c) => c.splitTunnelPackages),
      (List<String>? previous, List<String> next) {
        if (!setEquals(_selected, next.toSet())) {
          setState(() => _selected = next.toSet());
        }
      },
    );

    final AsyncValue<List<InstalledApp>> apps = ref.watch(
      installedAppsProvider,
    );
    final String? ownPackage = ref
        .watch(appPackageInfoProvider)
        .value
        ?.packageName;
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus s) => s.state.isActive),
    );
    final bool listEnabled = mode != SplitTunnelMode.off;

    return AikoScaffold(
      title: l10n.t('perApp.title'),
      actions: <Widget>[
        PopupMenuButton<String>(
          key: const Key('per-app-menu'),
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (String action) =>
              _onMenu(action, apps.value ?? const <InstalledApp>[], ownPackage),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              enabled: listEnabled,
              value: 'all',
              child: Text(l10n.t('common.selectAll')),
            ),
            PopupMenuItem<String>(
              enabled: listEnabled,
              value: 'none',
              child: Text(l10n.t('common.selectNone')),
            ),
            PopupMenuItem<String>(
              enabled: listEnabled,
              value: 'invert',
              child: Text(l10n.t('perApp.invertSelection')),
            ),
            const PopupMenuDivider(),
            CheckedPopupMenuItem<String>(
              value: 'sort-name',
              checked: _sort == PerAppSort.name,
              child: Text(l10n.t('perApp.sort.name')),
            ),
            CheckedPopupMenuItem<String>(
              value: 'sort-selected',
              checked: _sort == PerAppSort.selectedFirst,
              child: Text(l10n.t('perApp.sort.selected')),
            ),
          ],
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionListHeader(title: l10n.t('perApp.mode.title'), isFirst: true),
          AikoChoiceChips<SplitTunnelMode>(
            options: <AikoChoiceOption<SplitTunnelMode>>[
              AikoChoiceOption<SplitTunnelMode>(
                value: SplitTunnelMode.off,
                label: l10n.t('perApp.mode.off'),
              ),
              AikoChoiceOption<SplitTunnelMode>(
                value: SplitTunnelMode.allow,
                label: l10n.t('perApp.mode.allowlist'),
              ),
              AikoChoiceOption<SplitTunnelMode>(
                value: SplitTunnelMode.deny,
                label: l10n.t('perApp.mode.denylist'),
              ),
            ],
            value: mode,
            onChanged: (SplitTunnelMode next) => _setMode(next),
          ),
          const SizedBox(height: 8),
          SettingsNote(_hintFor(l10n, mode)),
          if (running)
            SettingsNote(
              l10n.t('perApp.restartHint'),
              icon: Icons.info_outline_rounded,
            ),
          if (listEnabled) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AikoDims.pagePadding,
                0,
                AikoDims.pagePadding,
                8,
              ),
              child: TextField(
                key: const Key('per-app-search'),
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l10n.t('perApp.search'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.t('common.clear'),
                          icon: const Icon(Icons.close_rounded),
                          onPressed: _search.clear,
                        ),
                ),
              ),
            ),
            SettingsNote(
              l10n.plural('plural.apps', _selected.length),
              icon: Icons.check_circle_outline_rounded,
            ),
            SettingsSwitchTile(
              tileKey: const Key('per-app-system'),
              title: l10n.t('perApp.showSystemApps'),
              value: _showSystem,
              onChanged: (bool value) => setState(() => _showSystem = value),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: !listEnabled
                // Nothing to pick while every app uses the tunnel; a greyed-out
                // list of three hundred checkboxes would only be noise.
                ? EmptyState(
                    icon: Icons.all_inclusive_rounded,
                    title: l10n.t('perApp.mode.off'),
                    message: l10n.t('perApp.description'),
                  )
                : apps.when(
                    loading: () => _Loading(message: l10n.t('perApp.loading')),
                    error: (Object error, StackTrace stack) => EmptyState(
                      icon: Icons.error_outline_rounded,
                      title: l10n.t('common.error.default'),
                      message: l10n.t('perApp.empty'),
                      action: FilledButton.tonal(
                        onPressed: () => ref.invalidate(installedAppsProvider),
                        child: Text(l10n.t('common.retry')),
                      ),
                    ),
                    data: (List<InstalledApp> all) =>
                        _buildList(context, l10n, all, ownPackage),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AikoL10n l10n,
    List<InstalledApp> all,
    String? ownPackage,
  ) {
    final List<InstalledApp> visible = _visibleApps(all, ownPackage);
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.filter_alt_off_rounded,
        title: l10n.t('perApp.empty'),
        message: l10n.t('perApp.description'),
      );
    }

    final bool selfHidden =
        ownPackage != null &&
        all.any((InstalledApp app) => app.packageName == ownPackage);

    return ListView.builder(
      key: const Key('per-app-list'),
      padding: const EdgeInsets.only(bottom: AikoDims.fabClearance),
      itemCount: visible.length + (selfHidden ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (selfHidden && index == visible.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SettingsNote(
              l10n.t('perApp.selfLocked'),
              icon: Icons.lock_outline_rounded,
            ),
          );
        }
        final InstalledApp app = visible[index];
        final bool checked = _selected.contains(app.packageName);
        return CheckboxListTile(
          key: ValueKey<String>('per-app-${app.packageName}'),
          value: checked,
          controlAffinity: ListTileControlAffinity.trailing,
          secondary: _AppGlyph(label: app.label),
          title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            app.isSystem
                ? '${app.packageName} · ${l10n.t('perApp.systemLabel')}'
                : app.packageName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onChanged: (bool? value) {
            final Set<String> next = <String>{..._selected};
            if (value ?? false) {
              next.add(app.packageName);
            } else {
              next.remove(app.packageName);
            }
            _persist(next);
          },
        );
      },
    );
  }

  List<InstalledApp> _visibleApps(List<InstalledApp> all, String? ownPackage) {
    final String query = _search.text.trim().toLowerCase();
    final List<InstalledApp> filtered = all.where((InstalledApp app) {
      if (app.packageName == ownPackage) return false;
      if (!_showSystem && app.isSystem) {
        // A system app the user already picked stays visible, otherwise
        // hiding the category would silently strip it from the list.
        if (!_selected.contains(app.packageName)) return false;
      }
      if (query.isEmpty) return true;
      return app.label.toLowerCase().contains(query) ||
          app.packageName.toLowerCase().contains(query);
    }).toList();

    filtered.sort((InstalledApp a, InstalledApp b) {
      if (_sort == PerAppSort.selectedFirst) {
        final bool sa = _selected.contains(a.packageName);
        final bool sb = _selected.contains(b.packageName);
        if (sa != sb) return sa ? -1 : 1;
      }
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return filtered;
  }

  void _onMenu(String action, List<InstalledApp> all, String? ownPackage) {
    switch (action) {
      case 'sort-name':
        setState(() => _sort = PerAppSort.name);
      case 'sort-selected':
        setState(() => _sort = PerAppSort.selectedFirst);
      case 'all':
        {
          // Only what is on screen: "select all" while a filter is active must
          // not quietly add three hundred apps the user cannot see.
          _persist(<String>{
            ..._selected,
            for (final InstalledApp app in _visibleApps(all, ownPackage))
              app.packageName,
          });
        }
      case 'none':
        {
          _persist(
            _selected.difference(<String>{
              for (final InstalledApp app in _visibleApps(all, ownPackage))
                app.packageName,
            }),
          );
        }
      case 'invert':
        {
          final Set<String> next = <String>{..._selected};
          for (final InstalledApp app in _visibleApps(all, ownPackage)) {
            if (!next.remove(app.packageName)) next.add(app.packageName);
          }
          _persist(next);
        }
    }
  }

  static String _hintFor(AikoL10n l10n, SplitTunnelMode mode) => switch (mode) {
    SplitTunnelMode.off => l10n.t('perApp.mode.offHint'),
    SplitTunnelMode.allow => l10n.t('perApp.mode.allowlistHint'),
    SplitTunnelMode.deny => l10n.t('perApp.mode.denylistHint'),
  };
}

class _Loading extends StatelessWidget {
  const _Loading({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// `installedApps()` returns labels, not icons, so a row is identified by its
/// initial rather than by a fake placeholder icon.
class _AppGlyph extends StatelessWidget {
  const _AppGlyph({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String initial = label.isEmpty
        ? '?'
        : label.characters.first.toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(
        initial,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
