/// Riverpod wiring for the profiles feature, and the controller the screens
/// call into.
///
/// Everything user-visible goes through [ProfilesController] rather than
/// touching `ProfileStore` from a widget, for three reasons:
///
///  * a write that changes a profile's *content* has to tell the overlay store
///    about it, or an override is silently lost on the next refresh (N5);
///  * a write to the profile the core is running has to be followed by an
///    explicit reload, and nothing else in the app knows to do that;
///  * "update all" has to serialise, and a single owner is what makes
///    [ProfilesBusyNotifier] able to say truthfully whether a write is in
///    flight.
library;

import 'dart:async';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'profile_batch_update.dart';
import 'profile_overlay_store.dart';
import 'profile_secret_store.dart';
import 'rule_editor_model.dart';
import 'rule_overlay.dart';
import 'rule_syntax.dart';
import 'yaml_document.dart';

// ---------------------------------------------------------------------------
// Stores
// ---------------------------------------------------------------------------

final profileSecretStoreProvider = Provider<ProfileSecretStore>(
  (ref) => ProfileSecretStore(),
);

final profileOverlayStoreProvider = FutureProvider<ProfileOverlayStore>((
  ref,
) async {
  final dirs = await ref.watch(aikoDirsProvider.future);
  final profiles = await ref.watch(profileStoreProvider.future);
  return ProfileOverlayStore(
    dirs: dirs,
    readProfile: profiles.readProfileText,
    writeProfile: profiles.writeProfileText,
  );
});

// ---------------------------------------------------------------------------
// Per-profile reads
// ---------------------------------------------------------------------------

/// The override document for one profile.
final profileOverlayProvider =
    FutureProvider.family<StoredOverlay, String>((ref, id) async {
      final store = await ref.watch(profileOverlayStoreProvider.future);
      return store.readOverlay(id);
    });

/// The profile's own YAML — the pristine snapshot when an override is in
/// force, the profile file itself otherwise.
final profileSourceProvider = FutureProvider.family<String, String>((
  ref,
  id,
) async {
  final store = await ref.watch(profileOverlayStoreProvider.future);
  return store.readProfileSource(id);
});

/// The rules editor's initial state: the profile's own rules with the override
/// folded in.
final profileRuleEditorProvider =
    FutureProvider.family<RuleEditorState, String>((ref, id) async {
      final store = await ref.watch(profileOverlayStoreProvider.future);
      final source = await store.readProfileSource(id);
      final stored = await store.readOverlay(id);
      Map<String, dynamic> clash;
      try {
        clash = parseYamlMap(source);
      } on YamlDocumentException {
        clash = <String, dynamic>{};
      }
      return RuleEditorState.load(
        parseProfileRules(clash),
        stored.overlay.rules,
      );
    });

/// Outbound names the rules editor offers: the profile's groups, then its
/// proxies, then mihomo's built-ins. Port of the `proxyGroups` list built in
/// `edit-rules-modal.tsx`.
final profileOutboundNamesProvider =
    FutureProvider.family<List<String>, String>((ref, id) async {
      final source = await ref.watch(profileSourceProvider(id).future);
      Map<String, dynamic> clash;
      try {
        clash = parseYamlMap(source);
      } on YamlDocumentException {
        clash = <String, dynamic>{};
      }

      final names = <String>[];
      for (final key in const <String>['proxy-groups', 'proxies']) {
        final node = clash[key];
        if (node is! List) continue;
        for (final entry in node) {
          if (entry is Map && entry['name'] is String) {
            final name = entry['name'] as String;
            if (name.isNotEmpty) names.add(name);
          }
        }
      }
      names.addAll(kBuiltinOutbounds);
      return List<String>.unmodifiable(<String>{...names});
    });

// ---------------------------------------------------------------------------
// Busy state
// ---------------------------------------------------------------------------

/// What the profiles page is currently doing.
class ProfilesBusy {
  const ProfilesBusy({
    this.importing = false,
    this.updatingAll = false,
    this.refreshingIds = const <String>{},
    this.batchDone = 0,
    this.batchTotal = 0,
  });

  static const ProfilesBusy idle = ProfilesBusy();

  final bool importing;
  final bool updatingAll;

  /// Profiles whose subscription is downloading right now.
  final Set<String> refreshingIds;

  final int batchDone;
  final int batchTotal;

  /// True while any write is in flight. The page disables every action on it,
  /// because two writers on one profile file is how a config gets corrupted.
  bool get isBusy =>
      importing || updatingAll || refreshingIds.isNotEmpty;

  bool isRefreshing(String id) => refreshingIds.contains(id);

  ProfilesBusy copyWith({
    bool? importing,
    bool? updatingAll,
    Set<String>? refreshingIds,
    int? batchDone,
    int? batchTotal,
  }) => ProfilesBusy(
    importing: importing ?? this.importing,
    updatingAll: updatingAll ?? this.updatingAll,
    refreshingIds: refreshingIds ?? this.refreshingIds,
    batchDone: batchDone ?? this.batchDone,
    batchTotal: batchTotal ?? this.batchTotal,
  );
}

class ProfilesBusyNotifier extends Notifier<ProfilesBusy> {
  @override
  ProfilesBusy build() => ProfilesBusy.idle;

  void setImporting(bool value) =>
      state = state.copyWith(importing: value);

  void beginRefresh(String id) => state = state.copyWith(
    refreshingIds: <String>{...state.refreshingIds, id},
  );

  void endRefresh(String id) => state = state.copyWith(
    refreshingIds: <String>{...state.refreshingIds}..remove(id),
  );

  void beginBatch(int total) => state = state.copyWith(
    updatingAll: true,
    batchDone: 0,
    batchTotal: total,
  );

  void batchProgress(int done, int total) =>
      state = state.copyWith(batchDone: done, batchTotal: total);

  void endBatch() => state = state.copyWith(
    updatingAll: false,
    batchDone: 0,
    batchTotal: 0,
  );
}

final profilesBusyProvider =
    NotifierProvider<ProfilesBusyNotifier, ProfilesBusy>(
      ProfilesBusyNotifier.new,
    );

// ---------------------------------------------------------------------------
// The controller
// ---------------------------------------------------------------------------

final profilesControllerProvider = Provider<ProfilesController>(
  ProfilesController.new,
);

/// Every write the profiles screens perform.
class ProfilesController {
  ProfilesController(this._ref);

  final Ref _ref;

  ProfilesNotifier get _profiles => _ref.read(profilesProvider.notifier);

  ProfilesBusyNotifier get _busy => _ref.read(profilesBusyProvider.notifier);

  ProfileSecretStore get _secrets => _ref.read(profileSecretStoreProvider);

  Future<ProfileStore> get _store => _ref.read(profileStoreProvider.future);

  Future<ProfileOverlayStore> get _overlays =>
      _ref.read(profileOverlayStoreProvider.future);

  // ---------------------------------------------------------------- importing

  /// Imports a subscription with the desktop's full option set.
  ///
  /// [authToken] is kept in the Android keystore, not in `profile.yaml`, so a
  /// later refresh can reuse it without the user retyping it.
  Future<ProfileItem> importRemote({
    required String url,
    String? name,
    String? authToken,
    String? userAgent,
    bool autoUpdate = false,
    int? intervalMinutes,
    String? cron,
    bool fixedInterval = false,
    int? updateTimeoutSeconds,
  }) async {
    _busy.setImporting(true);
    try {
      final store = await _store;
      final appConfig = _ref.read(appConfigProvider);
      final item = await store.importRemote(
        url: url.trim(),
        name: name,
        authToken: authToken,
        userAgent: userAgent,
        autoUpdate: autoUpdate,
        intervalMinutes: intervalMinutes,
        timeout: Duration(
          milliseconds: updateTimeoutSeconds != null
              ? (updateTimeoutSeconds * 1000).clamp(1000, 300000)
              : appConfig.subscriptionTimeout.clamp(1000, 300000),
        ),
      );

      if (updateTimeoutSeconds != null) {
        await store.patchItem(
          item.id,
          (current) => current.copyWith(updateTimeout: updateTimeoutSeconds),
        );
      }
      await _secrets.writeAuthToken(item.id, authToken);
      await _saveSchedule(item.id, cron: cron, fixedInterval: fixedInterval);

      _invalidateList();
      return item;
    } finally {
      _busy.setImporting(false);
    }
  }

  /// Stores a picked or pasted Clash YAML as a local profile.
  Future<ProfileItem> importLocal({
    required String name,
    required String content,
  }) async {
    _busy.setImporting(true);
    try {
      final item = await _profiles.importLocal(name: name, content: content);
      _invalidateList();
      return item;
    } finally {
      _busy.setImporting(false);
    }
  }

  // ---------------------------------------------------------------- updating

  /// Re-downloads one subscription and re-applies its override.
  Future<void> refresh(String id) async {
    _busy.beginRefresh(id);
    try {
      await _refreshUnguarded(id);
    } finally {
      _busy.endRefresh(id);
    }
  }

  Future<void> _refreshUnguarded(String id) async {
    final token = await _secrets.readAuthToken(id);
    await _profiles.updateSubscription(id, authToken: token);
    await (await _overlays).adoptDownloadedProfile(id);
    _invalidateProfile(id);
    await _reloadIfCurrent(id);
  }

  /// Refreshes every subscription, sequentially, with the active profile last.
  Future<ProfileBatchResult> updateAll() async {
    final items = _ref.read(profilesProvider).value ?? const <ProfileItem>[];
    final currentId = _ref.read(currentProfileIdProvider);
    final total = items.where(isBatchUpdatable).length;
    if (total == 0) return ProfileBatchResult.empty;

    _busy.beginBatch(total);
    try {
      return await runProfileBatchUpdate(
        items,
        currentId,
        (item) => _refreshUnguarded(item.id),
        onProgress: (item, index, count) =>
            _busy.batchProgress(index, count),
      );
    } finally {
      _busy.endBatch();
      _invalidateList();
    }
  }

  // ------------------------------------------------------------------ editing

  /// Applies the "edit information" form.
  ///
  /// Only the fields the form owns are touched; everything else on the item —
  /// `updated`, `extra`, `home` — is left exactly as the last download set it.
  Future<void> saveInfo(
    String id, {
    required String name,
    String? url,
    String? userAgent,
    required bool autoUpdate,
    int? intervalMinutes,
    String? cron,
    required bool fixedInterval,
    int? updateTimeoutSeconds,
    String? authToken,
    bool clearAuthToken = false,
  }) async {
    final store = await _store;
    await store.patchItem(
      id,
      (current) => ProfileItem(
        id: current.id,
        type: current.type,
        name: name.trim().isEmpty ? current.name : name.trim(),
        url: (url ?? current.url)?.trim().isEmpty ?? true
            ? null
            : (url ?? current.url)!.trim(),
        updated: current.updated,
        interval: intervalMinutes,
        autoUpdate: autoUpdate,
        extra: current.extra,
        home: current.home,
        userAgent: (userAgent ?? '').trim().isEmpty ? null : userAgent!.trim(),
        updateTimeout: updateTimeoutSeconds,
      ),
    );

    if (clearAuthToken) {
      await _secrets.forget(id);
    } else if (authToken != null) {
      await _secrets.writeAuthToken(id, authToken);
    }

    await _saveSchedule(id, cron: cron, fixedInterval: fixedInterval);
    _invalidateList();
    _invalidateProfile(id);
  }

  Future<void> rename(String id, String name) async {
    await _profiles.rename(id, name);
    _invalidateList();
  }

  /// Saves a hand edit of the profile's own YAML and reloads the core when the
  /// profile is the running one.
  Future<void> saveProfileSource(String id, String content) async {
    await (await _overlays).saveProfileSource(id, content);
    _invalidateProfile(id);
    await _reloadIfCurrent(id);
  }

  /// Saves an override document. [source] preserves the user's own formatting
  /// when the raw editor wrote it.
  Future<void> saveOverlay(
    String id,
    ProfileOverlay overlay, {
    String? source,
  }) async {
    await (await _overlays).saveOverlay(id, overlay, source: source);
    _invalidateProfile(id);
    await _reloadIfCurrent(id);
  }

  /// Replaces only the rules half of a profile's override, leaving any YAML
  /// patch and schedule alone.
  Future<void> saveRuleOverlay(String id, RuleOverlay rules) async {
    final store = await _overlays;
    final current = (await store.readOverlay(id)).overlay;
    await store.saveOverlay(id, current.copyWith(rules: rules));
    _invalidateProfile(id);
    await _reloadIfCurrent(id);
  }

  /// Drops the override document and restores the pristine profile.
  Future<void> clearOverlay(String id) async {
    await (await _overlays).clearOverlay(id);
    _invalidateProfile(id);
    await _reloadIfCurrent(id);
  }

  // ------------------------------------------------------------------ the list

  /// Persists a drag-reorder.
  ///
  /// [newIndex] is the destination *after* the dragged item has been taken out
  /// of the list — the convention `ReorderableListView.onReorderItem` uses.
  ///
  /// `ProfilesNotifier` has no reorder method, so this writes the index through
  /// `ProfileStore.updateConfig` — the same serialised, atomic path every other
  /// index write uses (N6) — and then re-reads it.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final store = await _store;
    await store.updateConfig((config) {
      final items = List<ProfileItem>.of(config.items);
      if (oldIndex < 0 || oldIndex >= items.length) return config;
      final moved = items.removeAt(oldIndex);
      items.insert(newIndex.clamp(0, items.length), moved);
      return config.copyWith(items: items);
    });
    _invalidateList();
  }

  /// Switches the active profile. Reloads the core when it is running.
  Future<void> select(String id) =>
      _ref.read(currentProfileIdProvider.notifier).select(id);

  /// Deletes a profile and everything this feature keeps beside it.
  Future<void> remove(String id) async {
    await _profiles.remove(id);
    await (await _overlays).forget(id);
    await _secrets.forget(id);
    _invalidateProfile(id);
    _invalidateList();
  }

  // ---------------------------------------------------------------------------

  Future<void> _saveSchedule(
    String id, {
    String? cron,
    required bool fixedInterval,
  }) async {
    final store = await _overlays;
    final current = (await store.readOverlay(id)).overlay;
    final next = ProfileSchedule(
      cron: (cron ?? '').trim().isEmpty ? null : cron!.trim(),
      fixedInterval: fixedInterval,
    );
    if (next == current.schedule) return;
    await store.saveOverlay(id, current.copyWith(schedule: next));
  }

  /// Restarts the core when the profile that changed is the one it is running.
  ///
  /// `reloadProfile` runs the whole validate-then-swap pipeline, so a broken
  /// edit cannot take the tunnel down (N2/N3).
  Future<void> _reloadIfCurrent(String id) async {
    if (_ref.read(currentProfileIdProvider) != id) return;
    if (!_ref.read(coreStatusProvider).isRunning) return;
    await _ref.read(coreControllerProvider).reloadProfile(id);
  }

  void _invalidateList() {
    _ref.invalidate(profilesProvider);
  }

  void _invalidateProfile(String id) {
    _ref.invalidate(profileOverlayProvider(id));
    _ref.invalidate(profileSourceProvider(id));
    _ref.invalidate(profileRuleEditorProvider(id));
    _ref.invalidate(profileOutboundNamesProvider(id));
  }
}
