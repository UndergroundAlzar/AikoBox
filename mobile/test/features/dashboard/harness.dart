/// Test scaffolding for the dashboard.
///
/// Every provider the dashboard reads is overridden here, so a card test never
/// touches `path_provider`, the platform channel or the network. The l10n
/// bundle is primed straight off disk the same way `test/l10n/locales_test.dart`
/// does it — `rootBundle` has no asset manifest under `flutter test`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main entry point.
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// l10n
// ---------------------------------------------------------------------------

Directory localesDir() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    final Directory candidate = Directory('${dir.path}/assets/locales');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('assets/locales not found from ${Directory.current.path}');
}

/// Serves the locale JSON off disk, synchronously, so `FakeAsync` can drive it.
class DiskBundle extends CachingAssetBundle {
  DiskBundle(this.root);

  final String root;

  File _fileFor(String key) => File('$root/${key.split('/').last}');

  @override
  Future<ByteData> load(String key) {
    final File file = _fileFor(key);
    if (!file.existsSync()) {
      return Future<ByteData>.error(FlutterError('asset not found: $key'));
    }
    return SynchronousFuture<ByteData>(
      ByteData.sublistView(file.readAsBytesSync()),
    );
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    final File file = _fileFor(key);
    if (!file.existsSync()) {
      return Future<String>.error(FlutterError('asset not found: $key'));
    }
    return SynchronousFuture<String>(file.readAsStringSync(encoding: utf8));
  }
}

/// Loads en-US into the shared bundle cache. Call from `setUp`.
Future<AikoL10n> primeEnglish() async {
  AikoL10n.resetForTests();
  return AikoL10n.load(
    const Locale('en', 'US'),
    bundle: DiskBundle(localesDir().path),
  );
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A [CoreChannel] that answers without a platform.
class FakeCoreChannel implements CoreChannel {
  FakeCoreChannel({
    this.consentGranted = true,
    this.version = 'sing-box 1.13.0-aiko',
  });

  bool consentGranted;
  String version;

  int prepareCalls = 0;
  int requestCalls = 0;

  @override
  Future<bool> prepareVpn() async {
    prepareCalls++;
    return consentGranted;
  }

  @override
  Future<bool> requestVpnPermission() async {
    requestCalls++;
    return consentGranted;
  }

  @override
  Future<void> start(
    String configJson, {
    List<String> includePackages = const <String>[],
    List<String> excludePackages = const <String>[],
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<String?> checkConfig(String json) async => null;

  @override
  Future<String> coreVersion() async => version;

  @override
  Future<List<InstalledApp>> installedApps() async => const <InstalledApp>[];

  @override
  Future<int> clashApiPort() async => 9090;

  @override
  Future<String> clashApiSecret() async => 'secret';

  @override
  Stream<CoreStatusEvent> statusEvents() =>
      const Stream<CoreStatusEvent>.empty();

  @override
  Stream<LogLine> logEvents() => const Stream<LogLine>.empty();
}

/// Records what the UI asked the tunnel to do.
class FakeCoreController implements CoreController {
  int startCalls = 0;
  int stopCalls = 0;
  final List<OutboundMode> modes = <OutboundMode>[];
  final List<String> reloaded = <String>[];

  /// Thrown by [start] when set.
  Object? startError;

  @override
  Future<void> start() async {
    startCalls++;
    final Object? error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> reloadProfile(String profileId) async => reloaded.add(profileId);

  @override
  Future<void> setMode(OutboundMode mode) async => modes.add(mode);

  @override
  Future<void> selectProxy(String group, String node) async {}

  @override
  Future<int?> testDelay(String node) async => null;

  @override
  Future<Map<String, int>> testGroupDelay(String group) async =>
      const <String, int>{};

  @override
  Future<void> closeConnection(String id) async {}

  @override
  Future<void> closeAllConnections() async {}
}

/// Holds the config across notifier rebuilds so a test can read what was
/// written.
class ConfigRecorder {
  ConfigRecorder(this.value);
  AppConfig value;
}

class FakeCoreStatusNotifier extends CoreStatusNotifier {
  FakeCoreStatusNotifier(this._value);
  final CoreStatus _value;

  @override
  CoreStatus build() => _value;
}

class FakeAppConfigNotifier extends AppConfigNotifier {
  FakeAppConfigNotifier(this.recorder);
  final ConfigRecorder recorder;

  @override
  AppConfig build() => recorder.value;

  @override
  Future<AppConfig> update(AppConfig Function(AppConfig) updater) async {
    final AppConfig next = updater(recorder.value);
    recorder.value = next;
    state = next;
    return next;
  }
}

class FakeLogsNotifier extends LogsNotifier {
  FakeLogsNotifier(this._value);
  final List<LogLine> _value;

  @override
  List<LogLine> build() => _value;
}

class FakeProxiesNotifier extends ProxiesNotifier {
  FakeProxiesNotifier(this._value);
  final ProxiesSnapshot _value;

  @override
  Future<ProxiesSnapshot> build() => SynchronousFuture<ProxiesSnapshot>(_value);
}

class FakeOutboundModeNotifier extends OutboundModeNotifier {
  FakeOutboundModeNotifier(this._mode, this.selections);
  final OutboundMode _mode;
  final List<OutboundMode> selections;

  @override
  Future<OutboundMode> build() => SynchronousFuture<OutboundMode>(_mode);

  @override
  Future<void> setMode(OutboundMode mode) async {
    selections.add(mode);
    state = AsyncValue<OutboundMode>.data(mode);
  }
}

class FakeProfilesNotifier extends ProfilesNotifier {
  FakeProfilesNotifier(this._items, this.updated);
  final List<ProfileItem> _items;
  final List<String> updated;

  @override
  Future<List<ProfileItem>> build() =>
      SynchronousFuture<List<ProfileItem>>(_items);

  @override
  Future<ProfileItem> updateSubscription(String id, {String? authToken}) async {
    updated.add(id);
    return _items.firstWhere((ProfileItem item) => item.id == id);
  }
}

class FakeTrafficHistoryNotifier extends TrafficHistoryNotifier {
  FakeTrafficHistoryNotifier(this._points);
  final List<TrafficPoint> _points;

  @override
  List<TrafficPoint> build() => _points;
}

class FakeNetworkLatencyNotifier extends NetworkLatencyNotifier {
  FakeNetworkLatencyNotifier(this._results, this.refreshCount);
  final List<LatencyProbeResult> _results;
  final List<int> refreshCount;

  @override
  Future<List<LatencyProbeResult>> build() =>
      SynchronousFuture<List<LatencyProbeResult>>(_results);

  @override
  Future<void> refresh() async => refreshCount.add(1);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Everything a dashboard test can vary, plus the recorders it can inspect.
class DashboardHarness {
  DashboardHarness({
    this.status = CoreStatus.stopped,
    AppConfig config = AppConfig.defaults,
    this.profile,
    this.profiles = const <ProfileItem>[],
    this.proxies = ProxiesSnapshot.empty,
    this.mode = OutboundMode.rule,
    this.connections,
    this.rules = const <RuleItem>[],
    this.proxyProviders = const <String, ProviderInfo>{},
    this.ruleProviders = const <String, ProviderInfo>{},
    this.logs = const <LogLine>[],
    this.traffic = const <TrafficPoint>[],
    this.totals,
    this.memory,
    this.summary = ProfileRuntimeSummary.none,
    this.latency = const <LatencyProbeResult>[],
    FakeCoreChannel? channel,
    FakeCoreController? controller,
    this.navigate,
  }) : configRecorder = ConfigRecorder(config),
       channel = channel ?? FakeCoreChannel(),
       controller = controller ?? FakeCoreController();

  final CoreStatus status;
  final ConfigRecorder configRecorder;
  final ProfileItem? profile;
  final List<ProfileItem> profiles;
  final ProxiesSnapshot proxies;
  final OutboundMode mode;
  final List<ConnectionInfo>? connections;
  final List<RuleItem> rules;
  final Map<String, ProviderInfo> proxyProviders;
  final Map<String, ProviderInfo> ruleProviders;
  final List<LogLine> logs;
  final List<TrafficPoint> traffic;
  final ({int up, int down})? totals;
  final MemoryPoint? memory;
  final ProfileRuntimeSummary summary;
  final List<LatencyProbeResult> latency;
  final FakeCoreChannel channel;
  final FakeCoreController controller;
  final DashboardNavigate? navigate;

  /// Modes the outbound card asked for.
  final List<OutboundMode> modeSelections = <OutboundMode>[];

  /// Profile ids the profile card refreshed.
  final List<String> profileUpdates = <String>[];

  /// One entry per latency refresh.
  final List<int> latencyRefreshes = <int>[];

  /// Destinations the shell was asked to open.
  final List<DashboardDestination> opened = <DashboardDestination>[];

  AppConfig get config => configRecorder.value;

  List<Override> get overrides => <Override>[
    coreChannelProvider.overrideWithValue(channel),
    coreControllerProvider.overrideWithValue(controller),
    coreStatusProvider.overrideWith(() => FakeCoreStatusNotifier(status)),
    appConfigProvider.overrideWith(() => FakeAppConfigNotifier(configRecorder)),
    logsProvider.overrideWith(() => FakeLogsNotifier(logs)),
    proxiesProvider.overrideWith(() => FakeProxiesNotifier(proxies)),
    outboundModeProvider.overrideWith(
      () => FakeOutboundModeNotifier(mode, modeSelections),
    ),
    profilesProvider.overrideWith(
      () => FakeProfilesNotifier(profiles, profileUpdates),
    ),
    currentProfileProvider.overrideWithValue(profile),
    rulesProvider.overrideWith((Ref ref) => rules),
    proxyProvidersProvider.overrideWith((Ref ref) => proxyProviders),
    ruleProvidersProvider.overrideWith((Ref ref) => ruleProviders),
    connectionsProvider.overrideWith(
      (Ref ref) => connections == null
          ? const Stream<List<ConnectionInfo>>.empty()
          : Stream<List<ConnectionInfo>>.value(connections!),
    ),
    totalTrafficProvider.overrideWith(
      (Ref ref) => totals == null
          ? const Stream<({int up, int down})>.empty()
          : Stream<({int up, int down})>.value(totals!),
    ),
    trafficProvider.overrideWith(
      (Ref ref) => traffic.isEmpty
          ? const Stream<TrafficPoint>.empty()
          : Stream<TrafficPoint>.value(traffic.last),
    ),
    memoryProvider.overrideWith(
      (Ref ref) => memory == null
          ? const Stream<MemoryPoint>.empty()
          : Stream<MemoryPoint>.value(memory!),
    ),
    trafficHistoryProvider.overrideWith(
      () => FakeTrafficHistoryNotifier(traffic),
    ),
    networkLatencyProvider.overrideWith(
      () => FakeNetworkLatencyNotifier(latency, latencyRefreshes),
    ),
    profileRuntimeSummaryProvider.overrideWith((Ref ref) => summary),
    coreVersionProvider.overrideWith((Ref ref) => channel.version),
    dashboardNavigateProvider.overrideWithValue(navigate ?? opened.add),
  ];
}

/// Pumps [child] inside a real theme, real l10n and the harness's overrides.
///
/// Uses explicit pumps rather than `pumpAndSettle`: a running FAB owns a
/// one-second ticker, and settling would never finish.
Future<void> pumpDashboardWidget(
  WidgetTester tester,
  Widget child, {
  required DashboardHarness harness,
  Size surfaceSize = const Size(420, 900),
  Brightness brightness = Brightness.light,
  int pumps = 3,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: harness.overrides,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AikoTheme.dark()
            : AikoTheme.light(),
        locale: const Locale('en', 'US'),
        supportedLocales: AikoL10n.supportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AikoL10nDelegate(),
        ],
        home: child,
      ),
    ),
  );
  for (int i = 0; i < pumps; i++) {
    await tester.pump();
  }
}
