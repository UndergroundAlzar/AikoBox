/// Riverpod 3 wiring for the whole core layer. No code generation.
///
/// The public providers are the ones fixed by the build contract (§4.3);
/// everything else in this file exists to feed them and may be used freely.
///
/// Call [bootstrapAikoCore] from `main()` before `runApp` so the first frame
/// does not race directory resolution. Nothing breaks if you forget — every
/// store resolves its own directories on first use — but the first frame will
/// briefly show defaults.
library;

import 'dart:async';

import 'package:aikobox_subscription/aikobox_subscription.dart'
    show redactSecrets;
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_config.dart';
import 'clash_api.dart';
import 'config_store.dart';
import 'core_channel.dart';
import 'core_controller.dart';
import 'models.dart';
import 'paths.dart';
import 'profile_store.dart';

export 'app_config.dart' show AppConfigStore;
export 'clash_api.dart' show ClashApi, ClashApiException;
export 'config_store.dart' show ConfigSlot, SerialTaskQueue, SingboxConfigStore;
export 'core_channel.dart' show AikoCoreException, CoreChannel, CoreStatusEvent;
export 'core_controller.dart' show CoreController, CoreStartException;
export 'models.dart';
export 'paths.dart' show AikoDirs;
export 'profile_store.dart'
    show
        ProfileConfig,
        ProfileStore,
        SubscriptionErrorCode,
        SubscriptionException;

/// Resolves the application directories ahead of the first frame.
Future<void> bootstrapAikoCore() async {
  await AikoDirs.ensure();
}

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

/// The platform channel. Overridden in tests with a fake.
final coreChannelProvider = Provider<CoreChannel>(
  (ref) => MethodChannelCoreChannel(),
);

final aikoDirsProvider = FutureProvider<AikoDirs>((ref) => AikoDirs.ensure());

final appConfigStoreProvider = FutureProvider<AppConfigStore>((ref) async {
  final dirs = await ref.watch(aikoDirsProvider.future);
  return AppConfigStore(dirs.appConfigFile);
});

final profileStoreProvider = FutureProvider<ProfileStore>((ref) async {
  final dirs = await ref.watch(aikoDirsProvider.future);
  final store = ProfileStore(dirs: dirs);
  ref.onDispose(store.close);
  return store;
});

final singboxConfigStoreProvider = FutureProvider<SingboxConfigStore>((
  ref,
) async {
  final dirs = await ref.watch(aikoDirsProvider.future);
  return SingboxConfigStore(dirs.workDir);
});

/// The real controller, once its stores have resolved.
final coreControllerAsyncProvider = FutureProvider<AikoCoreController>((
  ref,
) async {
  final controller = AikoCoreController(
    channel: ref.watch(coreChannelProvider),
    configStore: await ref.watch(singboxConfigStoreProvider.future),
    profileStore: await ref.watch(profileStoreProvider.future),
    appConfigStore: await ref.watch(appConfigStoreProvider.future),
  );
  ref.onDispose(() => unawaited(controller.dispose()));
  return controller;
});

/// The Clash API client for the currently running core.
///
/// Rebuilt on every start, because the core can come back on a different port
/// with a different secret.
final clashApiProvider = FutureProvider<ClashApi>((ref) async {
  ref.watch(coreStatusProvider.select((status) => status.startedAt));
  final controller = await ref.watch(coreControllerAsyncProvider.future);
  return controller.api();
});

/// The fixed §4.3 handle. Synchronous by contract, so it forwards to the real
/// controller as soon as that has resolved.
final coreControllerProvider = Provider<CoreController>(
  (ref) => _DeferredCoreController(ref),
);

/// Forwards [CoreController] calls to the controller once its stores are open.
///
/// This exists only because the contract fixes `coreControllerProvider` as a
/// synchronous `Provider`, while the stores behind it need `path_provider`.
class _DeferredCoreController implements CoreController {
  _DeferredCoreController(this._ref);

  final Ref _ref;

  Future<AikoCoreController> get _controller =>
      _ref.read(coreControllerAsyncProvider.future);

  @override
  Future<void> start() async => (await _controller).start();

  @override
  Future<void> stop() async => (await _controller).stop();

  @override
  Future<void> reloadProfile(String profileId) async =>
      (await _controller).reloadProfile(profileId);

  @override
  Future<void> setMode(OutboundMode mode) async =>
      (await _controller).setMode(mode);

  @override
  Future<void> selectProxy(String group, String node) async =>
      (await _controller).selectProxy(group, node);

  @override
  Future<int?> testDelay(String node) async =>
      (await _controller).testDelay(node);

  @override
  Future<Map<String, int>> testGroupDelay(String group) async =>
      (await _controller).testGroupDelay(group);

  @override
  Future<void> closeConnection(String id) async =>
      (await _controller).closeConnection(id);

  @override
  Future<void> closeAllConnections() async =>
      (await _controller).closeAllConnections();
}

// ---------------------------------------------------------------------------
// Core status
// ---------------------------------------------------------------------------

class CoreStatusNotifier extends Notifier<CoreStatus> {
  StreamSubscription<CoreStatus>? _subscription;

  @override
  CoreStatus build() {
    ref.onDispose(() => unawaited(_subscription?.cancel()));
    unawaited(_attach());
    return CoreStatus.stopped;
  }

  Future<void> _attach() async {
    final AikoCoreController controller;
    try {
      controller = await ref.read(coreControllerAsyncProvider.future);
    } catch (error) {
      if (ref.mounted) {
        state = CoreStatus(
          state: CoreState.failed,
          error: redactSecrets(error.toString()),
        );
      }
      return;
    }
    if (!ref.mounted) return;
    state = controller.status;
    _subscription = controller.statusStream.listen((next) {
      if (ref.mounted) state = next;
    });
  }
}

final coreStatusProvider = NotifierProvider<CoreStatusNotifier, CoreStatus>(
  CoreStatusNotifier.new,
);

// ---------------------------------------------------------------------------
// Live streams
// ---------------------------------------------------------------------------

/// Republishes an `AsyncValue`-shaped provider as a plain stream, so several
/// derived providers can share one upstream websocket.
Stream<R> _bridge<T, R>(
  Ref ref,
  StreamProvider<T> source,
  R Function(T value) map,
) {
  final controller = StreamController<R>();
  final subscription = ref.listen<AsyncValue<T>>(source, (previous, next) {
    if (controller.isClosed) return;
    next.whenOrNull<void>(
      data: (value) => controller.add(map(value)),
      error: (error, stackTrace) => controller.addError(error, stackTrace),
    );
  }, fireImmediately: true);
  ref.onDispose(() {
    subscription.close();
    unawaited(controller.close());
  });
  return controller.stream;
}

final trafficProvider = StreamProvider<TrafficPoint>((ref) async* {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return;
  final api = await ref.watch(clashApiProvider.future);
  yield* api.trafficStream();
});

final memoryProvider = StreamProvider<MemoryPoint>((ref) async* {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return;
  final api = await ref.watch(clashApiProvider.future);
  yield* api.memoryStream();
});

/// One `/connections` websocket, shared by [connectionsProvider] and
/// [totalTrafficProvider].
final connectionsSnapshotProvider = StreamProvider<ConnectionsSnapshot>((
  ref,
) async* {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return;
  final api = await ref.watch(clashApiProvider.future);
  yield* api.connectionsStream();
});

final connectionsProvider = StreamProvider<List<ConnectionInfo>>(
  (ref) => _bridge<ConnectionsSnapshot, List<ConnectionInfo>>(
    ref,
    connectionsSnapshotProvider,
    (snapshot) => snapshot.connections,
  ),
);

/// Cumulative bytes since the core started, for the traffic-totals card.
final totalTrafficProvider = StreamProvider<({int up, int down})>(
  (ref) => _bridge<ConnectionsSnapshot, ({int up, int down})>(
    ref,
    connectionsSnapshotProvider,
    (snapshot) => (up: snapshot.uploadTotal, down: snapshot.downloadTotal),
  ),
);

/// Log lines from the core's own `/logs` websocket.
final clashLogStreamProvider = StreamProvider<LogLine>((ref) async* {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return;
  final level = ref.watch(
    appConfigProvider.select((config) => config.logLevel),
  );
  if (level == LogLevel.silent) return;
  final api = await ref.watch(clashApiProvider.future);
  yield* api.logsStream(level: level);
});

/// Log lines the Android host emits about the service itself.
final hostLogStreamProvider = StreamProvider<LogLine>(
  (ref) => ref.watch(coreChannelProvider).logEvents(),
);

/// Notices the controller raises itself: converter warnings, refusals and
/// rollbacks. N5 — none of these is allowed to happen silently.
final coreNoticeStreamProvider = StreamProvider<LogLine>((ref) async* {
  final controller = await ref.watch(coreControllerAsyncProvider.future);
  yield* controller.noticeStream;
});

/// A bounded ring buffer of the most recent log lines, newest last.
class LogsNotifier extends Notifier<List<LogLine>> {
  final List<StreamSubscription<LogLine>> _subscriptions =
      <StreamSubscription<LogLine>>[];

  @override
  List<LogLine> build() {
    final limit = ref.watch(
      appConfigProvider.select((config) => config.maxLogLines),
    );
    ref.onDispose(() {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
    });
    ref.listen<AsyncValue<LogLine>>(clashLogStreamProvider, (previous, next) {
      next.whenOrNull(data: (line) => _append(line, limit));
    }, fireImmediately: true);
    ref.listen<AsyncValue<LogLine>>(hostLogStreamProvider, (previous, next) {
      next.whenOrNull(data: (line) => _append(line, limit));
    }, fireImmediately: true);
    ref.listen<AsyncValue<LogLine>>(coreNoticeStreamProvider, (previous, next) {
      next.whenOrNull(data: (line) => _append(line, limit));
    }, fireImmediately: true);
    return const <LogLine>[];
  }

  void _append(LogLine line, int limit) {
    if (!ref.mounted) return;
    final next = <LogLine>[...state, line];
    final overflow = next.length - limit;
    state = List<LogLine>.unmodifiable(
      overflow > 0 ? next.sublist(overflow) : next,
    );
  }

  void clear() {
    state = const <LogLine>[];
  }
}

final logsProvider = NotifierProvider<LogsNotifier, List<LogLine>>(
  LogsNotifier.new,
);

// ---------------------------------------------------------------------------
// Proxies
// ---------------------------------------------------------------------------

class ProxiesNotifier extends AsyncNotifier<ProxiesSnapshot> {
  @override
  Future<ProxiesSnapshot> build() async {
    final status = ref.watch(coreStatusProvider);
    if (status.state != CoreState.running) return ProxiesSnapshot.empty;
    final api = await ref.watch(clashApiProvider.future);
    return api.proxies();
  }

  /// Re-reads `/proxies` without dropping the current grid to a spinner.
  Future<void> refresh() async {
    final previous = state.value;
    try {
      final api = await ref.read(clashApiProvider.future);
      state = AsyncValue<ProxiesSnapshot>.data(await api.proxies());
    } catch (error, stackTrace) {
      state = previous == null
          ? AsyncValue<ProxiesSnapshot>.error(error, stackTrace)
          : AsyncValue<ProxiesSnapshot>.data(previous);
      rethrow;
    }
  }

  /// Selects [node] in [group], updating the grid before the core confirms.
  Future<void> select(String group, String node) async {
    final previous = state.value;
    if (previous != null) {
      state = AsyncValue<ProxiesSnapshot>.data(
        previous.withSelection(group, node),
      );
    }
    try {
      await ref.read(coreControllerProvider).selectProxy(group, node);
    } catch (error) {
      if (previous != null) state = AsyncValue<ProxiesSnapshot>.data(previous);
      rethrow;
    }
  }

  /// Probes one node and folds the result into the grid.
  Future<int?> testDelay(String node) async {
    final delay = await ref.read(coreControllerProvider).testDelay(node);
    final current = state.value;
    if (current != null) {
      state = AsyncValue<ProxiesSnapshot>.data(current.withDelay(node, delay));
    }
    return delay;
  }

  /// Probes every member of [group] and folds the results into the grid.
  Future<Map<String, int>> testGroupDelay(String group) async {
    final results = await ref
        .read(coreControllerProvider)
        .testGroupDelay(group);
    var current = state.value;
    if (current != null) {
      for (final entry in results.entries) {
        current = current!.withDelay(
          entry.key,
          entry.value > 0 ? entry.value : null,
        );
      }
      state = AsyncValue<ProxiesSnapshot>.data(current!);
    }
    return results;
  }
}

final proxiesProvider = AsyncNotifierProvider<ProxiesNotifier, ProxiesSnapshot>(
  ProxiesNotifier.new,
);

/// The outbound mode the core is actually in.
class OutboundModeNotifier extends AsyncNotifier<OutboundMode> {
  @override
  Future<OutboundMode> build() async {
    final status = ref.watch(coreStatusProvider);
    if (status.state != CoreState.running) return OutboundMode.rule;
    final api = await ref.watch(clashApiProvider.future);
    final configs = await api.configs();
    return OutboundMode.fromWire(configs['mode']);
  }

  Future<void> setMode(OutboundMode mode) async {
    final previous = state.value;
    state = AsyncValue<OutboundMode>.data(mode);
    try {
      await ref.read(coreControllerProvider).setMode(mode);
      ref.invalidate(proxiesProvider);
    } catch (error) {
      if (previous != null) state = AsyncValue<OutboundMode>.data(previous);
      rethrow;
    }
  }
}

final outboundModeProvider =
    AsyncNotifierProvider<OutboundModeNotifier, OutboundMode>(
      OutboundModeNotifier.new,
    );

final rulesProvider = FutureProvider<List<RuleItem>>((ref) async {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return const <RuleItem>[];
  final api = await ref.watch(clashApiProvider.future);
  return api.rules();
});

final proxyProvidersProvider = FutureProvider<Map<String, ProviderInfo>>((
  ref,
) async {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return const <String, ProviderInfo>{};
  final api = await ref.watch(clashApiProvider.future);
  return api.proxyProviders();
});

final ruleProvidersProvider = FutureProvider<Map<String, ProviderInfo>>((
  ref,
) async {
  final status = ref.watch(coreStatusProvider);
  if (status.state != CoreState.running) return const <String, ProviderInfo>{};
  final api = await ref.watch(clashApiProvider.future);
  return api.ruleProviders();
});

/// The installed-package list for the split-tunnel picker. Expensive on a
/// phone with hundreds of apps, so it is fetched once and cached.
final installedAppsProvider = FutureProvider<List<InstalledApp>>((ref) async {
  final apps = await ref.watch(coreChannelProvider).installedApps();
  final sorted = List<InstalledApp>.of(apps)
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return List<InstalledApp>.unmodifiable(sorted);
});

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

/// The id of the selected profile, kept separately so
/// [currentProfileProvider] can stay a synchronous `Provider`.
class CurrentProfileIdNotifier extends Notifier<String?> {
  @override
  String? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final store = await ref.read(profileStoreProvider.future);
      final config = await store.readConfig();
      if (ref.mounted) state = config.current;
    } catch (_) {
      // No index yet: the app has never imported a profile.
    }
  }

  /// Switches profile and reloads the core when it is running.
  Future<void> select(String id) async {
    final previous = state;
    state = id;
    try {
      await ref.read(coreControllerProvider).reloadProfile(id);
    } catch (error) {
      state = previous;
      rethrow;
    }
  }

  void adopt(String? id) {
    if (ref.mounted) state = id;
  }
}

final currentProfileIdProvider =
    NotifierProvider<CurrentProfileIdNotifier, String?>(
      CurrentProfileIdNotifier.new,
    );

class ProfilesNotifier extends AsyncNotifier<List<ProfileItem>> {
  @override
  Future<List<ProfileItem>> build() async {
    final store = await ref.watch(profileStoreProvider.future);
    final config = await store.readConfig(force: true);
    ref.read(currentProfileIdProvider.notifier).adopt(config.current);
    return config.items;
  }

  Future<ProfileStore> get _store => ref.read(profileStoreProvider.future);

  Future<void> _refresh() async {
    final store = await _store;
    final config = await store.readConfig(force: true);
    ref.read(currentProfileIdProvider.notifier).adopt(config.current);
    state = AsyncValue<List<ProfileItem>>.data(config.items);
  }

  /// Downloads a subscription and adds it.
  Future<ProfileItem> importRemote({
    required String url,
    String? name,
    String? authToken,
    bool autoUpdate = false,
    int? intervalMinutes,
  }) async {
    final store = await _store;
    final config = await ref
        .read(appConfigStoreProvider.future)
        .then((s) => s.read());
    final item = await store.importRemote(
      url: url,
      name: name,
      authToken: authToken,
      autoUpdate: autoUpdate,
      intervalMinutes: intervalMinutes,
      timeout: Duration(
        milliseconds: config.subscriptionTimeout.clamp(1000, 300000),
      ),
    );
    await _refresh();
    return item;
  }

  /// Stores a pasted or picked Clash YAML.
  Future<ProfileItem> importLocal({
    required String name,
    required String content,
  }) async {
    final store = await _store;
    final item = await store.importLocal(name: name, content: content);
    await _refresh();
    return item;
  }

  /// Re-downloads one subscription.
  Future<ProfileItem> updateSubscription(String id, {String? authToken}) async {
    final store = await _store;
    final item = await store.updateRemote(id, authToken: authToken);
    await _refresh();
    return item;
  }

  Future<void> rename(String id, String name) async {
    final store = await _store;
    await store.patchItem(id, (item) => item.copyWith(name: name));
    await _refresh();
  }

  Future<void> setAutoUpdate(
    String id, {
    required bool enabled,
    int? intervalMinutes,
  }) async {
    final store = await _store;
    await store.patchItem(
      id,
      (item) => item.copyWith(
        autoUpdate: enabled,
        interval: intervalMinutes ?? item.interval,
      ),
    );
    await _refresh();
  }

  Future<void> remove(String id) async {
    final store = await _store;
    await store.remove(id);
    await _refresh();
  }
}

final profilesProvider =
    AsyncNotifierProvider<ProfilesNotifier, List<ProfileItem>>(
      ProfilesNotifier.new,
    );

final currentProfileProvider = Provider<ProfileItem?>((ref) {
  final items = ref.watch(profilesProvider).value ?? const <ProfileItem>[];
  if (items.isEmpty) return null;
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return items.first;
  return items.firstWhereOrNull((item) => item.id == id) ?? items.first;
});

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Settings, available synchronously from the first frame.
///
/// [build] returns the defaults and hydrates from disk immediately afterwards,
/// so no screen has to handle a loading state for something this small.
class AppConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() {
    unawaited(_hydrate());
    return AppConfig.defaults;
  }

  Future<void> _hydrate() async {
    try {
      final store = await ref.read(appConfigStoreProvider.future);
      final config = await store.read();
      if (ref.mounted) state = config;
    } catch (_) {
      // Defaults are a legitimate answer when there is nothing on disk yet.
    }
  }

  /// Applies [updater], persists the result atomically, and publishes it.
  Future<AppConfig> update(
    AppConfig Function(AppConfig current) updater,
  ) async {
    final store = await ref.read(appConfigStoreProvider.future);
    final next = await store.update(updater);
    if (ref.mounted) state = next;
    return next;
  }
}

final appConfigProvider = NotifierProvider<AppConfigNotifier, AppConfig>(
  AppConfigNotifier.new,
);
