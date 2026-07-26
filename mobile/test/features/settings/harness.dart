/// Test scaffolding for the Tools section.
///
/// Self-contained on purpose: these pages touch shared_preferences,
/// package_info_plus and the core method channel, and every one of those has to
/// be a fake before a single frame is pumped.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Localisation off disk
// ---------------------------------------------------------------------------

/// Locates `assets/locales` from wherever the runner set the cwd.
Directory localesDir() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    final Directory candidate = Directory('${dir.path}/assets/locales');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('assets/locales not found from ${Directory.current.path}');
}

/// Serves the locale JSON synchronously — `testWidgets` runs inside `FakeAsync`,
/// where real file IO never completes and `loadString`'s isolate hand-off for
/// large files deadlocks.
class DiskLocaleBundle extends CachingAssetBundle {
  DiskLocaleBundle(this.root);

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

class _TestL10nDelegate extends LocalizationsDelegate<AikoL10n> {
  const _TestL10nDelegate(this.bundle);

  final AssetBundle bundle;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AikoL10n> load(Locale locale) => AikoL10n.load(locale, bundle: bundle);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AikoL10n> old) => false;
}

/// The English strings, for asserting on rendered copy without duplicating it.
Map<String, String> loadLocaleStrings([String tag = 'en-US']) {
  final Object? decoded = jsonDecode(
    File('${localesDir().path}/$tag.json').readAsStringSync(),
  );
  return (decoded! as Map<String, dynamic>).map(
    (String k, dynamic v) => MapEntry<String, String>(k, '$v'),
  );
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// `AppConfig` in memory. Records every write so a test can assert on what was
/// actually persisted rather than on what the widget merely rendered.
class FakeAppConfigNotifier extends AppConfigNotifier {
  FakeAppConfigNotifier(this.initial, {this.failWrites = false});

  final AppConfig initial;

  /// Makes [update] throw, exercising the "settings write failed" path.
  final bool failWrites;

  static final List<AppConfig> writes = <AppConfig>[];

  @override
  AppConfig build() => initial;

  @override
  Future<AppConfig> update(
    AppConfig Function(AppConfig current) updater,
  ) async {
    if (failWrites) throw StateError('write refused');
    state = updater(state);
    writes.add(state);
    return state;
  }
}

class FakeCoreStatusNotifier extends CoreStatusNotifier {
  FakeCoreStatusNotifier(this.initial);

  final CoreStatus initial;

  @override
  CoreStatus build() => initial;
}

/// Keeps the outbound mode in memory instead of reaching for the Clash API.
class FakeOutboundModeNotifier extends OutboundModeNotifier {
  FakeOutboundModeNotifier(this.initial);

  final OutboundMode initial;

  static final List<OutboundMode> applied = <OutboundMode>[];

  @override
  Future<OutboundMode> build() async => initial;

  @override
  Future<void> setMode(OutboundMode mode) async {
    applied.add(mode);
    state = AsyncValue<OutboundMode>.data(mode);
  }
}

/// A [CoreChannel] that answers from memory.
class FakeCoreChannel implements CoreChannel {
  FakeCoreChannel({
    this.apps = const <InstalledApp>[],
    this.version = 'sing-box 1.13.0',
  });

  final List<InstalledApp> apps;
  final String version;

  @override
  Future<List<InstalledApp>> installedApps() async => apps;

  @override
  Future<String> coreVersion() async => version;

  @override
  Future<int> clashApiPort() async => 19090;

  @override
  Future<String> clashApiSecret() async => 'secret';

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<bool> requestVpnPermission() async => true;

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
  Stream<CoreStatusEvent> statusEvents() =>
      const Stream<CoreStatusEvent>.empty();

  @override
  Stream<LogLine> logEvents() => const Stream<LogLine>.empty();
}

/// Records tunnel calls made by a settings page.
class RecordingCoreController implements CoreController {
  int startCalls = 0;
  int stopCalls = 0;
  final List<OutboundMode> modes = <OutboundMode>[];

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> reloadProfile(String profileId) async {}

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

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

/// Package identity used by every test in this directory.
const String kTestPackageName = 'com.aikobox.android';

/// Resets the plugin mocks and the recorded writes. Call from `setUp`.
void resetSettingsTestEnvironment({Map<String, Object> prefs = const {}}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(prefs);
  PackageInfo.setMockInitialValues(
    appName: 'AikoBox',
    packageName: kTestPackageName,
    version: '0.1.0',
    buildNumber: '1',
    buildSignature: '',
  );
  FakeAppConfigNotifier.writes.clear();
  FakeOutboundModeNotifier.applied.clear();
  AikoL10n.resetForTests();
}

/// The standard override set. Everything a Tools page can reach is faked.
List<Override> settingsOverrides({
  AppConfig config = AppConfig.defaults,
  CoreStatus status = CoreStatus.stopped,
  OutboundMode mode = OutboundMode.rule,
  List<InstalledApp> apps = const <InstalledApp>[],
  CoreController? controller,
  bool failWrites = false,
  List<Override> extra = const <Override>[],
}) => <Override>[
  appConfigProvider.overrideWith(
    () => FakeAppConfigNotifier(config, failWrites: failWrites),
  ),
  coreStatusProvider.overrideWith(() => FakeCoreStatusNotifier(status)),
  outboundModeProvider.overrideWith(() => FakeOutboundModeNotifier(mode)),
  coreChannelProvider.overrideWithValue(FakeCoreChannel(apps: apps)),
  coreControllerProvider.overrideWithValue(
    controller ?? RecordingCoreController(),
  ),
  ...extra,
];

/// Wraps [child] in a themed, localised, provider-scoped app.
Widget hostSettings(
  Widget child, {
  List<Override> overrides = const <Override>[],
  Locale locale = const Locale('en', 'US'),
  Brightness brightness = Brightness.light,
}) {
  final AssetBundle bundle = DiskLocaleBundle(localesDir().path);
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: brightness == Brightness.dark
          ? AikoTheme.dark()
          : AikoTheme.light(),
      locale: locale,
      supportedLocales: AikoL10n.supportedLocales,
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        _TestL10nDelegate(bundle),
        ...AikoL10n.localizationsDelegates.skip(1),
      ],
      home: child,
    ),
  );
}

/// Pumps [child] and settles the async work the pages kick off on first build.
Future<void> pumpSettings(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  Size surface = const Size(420, 900),
  Locale locale = const Locale('en', 'US'),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    hostSettings(child, overrides: overrides, locale: locale),
  );
  await tester.pumpAndSettle();
}

/// A handful of installed apps, one of them ours and one a system package.
List<InstalledApp> sampleApps() => const <InstalledApp>[
  InstalledApp(
    packageName: 'com.example.browser',
    label: 'Browser',
    isSystem: false,
  ),
  InstalledApp(packageName: 'com.example.chat', label: 'Chat', isSystem: false),
  InstalledApp(
    packageName: 'com.android.settings',
    label: 'Settings',
    isSystem: true,
  ),
  InstalledApp(
    packageName: kTestPackageName,
    label: 'AikoBox',
    isSystem: false,
  ),
];
