/// Shared scaffolding for the connections/logs/rules widget tests.
///
/// Three things every one of these tests needs and none of them should build
/// itself: the real AikoBox theme, real translations loaded off disk, and a
/// `ProviderScope` whose core providers are fakes rather than a live tunnel.
///
/// It lives at the `test/features/` root rather than in one feature folder
/// because three areas share it. Other areas keep their own `harness.dart`
/// inside their directory; **do not rename this file** — tests outside
/// connections/logs/rules import it as `../harness.dart` too.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Serves the locale JSON straight off disk, synchronously.
///
/// `testWidgets` runs inside `FakeAsync`, where real file IO never completes
/// and `AssetBundle.loadString`'s isolate hand-off for large files deadlocks.
/// Both are avoided by reading synchronously here.
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

/// Loads [AikoL10n] through [DiskLocaleBundle] instead of `rootBundle`.
class TestL10nDelegate extends LocalizationsDelegate<AikoL10n> {
  const TestL10nDelegate(this.bundle);

  final AssetBundle bundle;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AikoL10n> load(Locale locale) =>
      AikoL10n.load(locale, bundle: bundle);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AikoL10n> old) => false;
}

/// The English strings, read once, for asserting on rendered copy.
Map<String, String> loadLocaleStrings([String tag = 'en-US']) {
  final Object? decoded = jsonDecode(
    File('${localesDir().path}/$tag.json').readAsStringSync(),
  );
  return (decoded! as Map<String, dynamic>).map(
    (String k, dynamic v) => MapEntry<String, String>(k, '$v'),
  );
}

/// Wraps [child] in a themed, localised, provider-scoped app.
///
/// The scope is [UncontrolledProviderScope] over a container the test built,
/// rather than `ProviderScope(overrides: …)`, for two reasons: the test keeps a
/// handle it can `read` from, and nothing here has to name the `Override` type —
/// `flutter_riverpod` does not re-export it and `riverpod` is only a transitive
/// dependency.
Widget hostPage(
  Widget child, {
  required ProviderContainer container,
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en', 'US'),
}) {
  final AssetBundle bundle = DiskLocaleBundle(localesDir().path);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: brightness == Brightness.dark
          ? AikoTheme.dark()
          : AikoTheme.light(),
      locale: locale,
      supportedLocales: AikoL10n.supportedLocales,
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        TestL10nDelegate(bundle),
        ...AikoL10n.localizationsDelegates.skip(1),
      ],
      home: child,
    ),
  );
}

/// Pumps [child] at a phone-shaped viewport and settles the one microtask the
/// l10n delegate needs.
///
/// The viewport is set through `tester.view` with a device pixel ratio of 1, so
/// [surface] is logical pixels and means what it says. (`setSurfaceSize` leaves
/// the default 800×600 landscape window in place under this Flutter version,
/// which quietly tests a layout no phone has.)
Future<void> pumpPage(
  WidgetTester tester,
  Widget child, {
  required ProviderContainer container,
  Size surface = const Size(400, 800),
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en', 'US'),
}) async {
  tester.view
    ..devicePixelRatio = 1.0
    ..physicalSize = surface;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    hostPage(
      child,
      container: container,
      brightness: brightness,
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Fakes for the core providers
// ---------------------------------------------------------------------------

/// A [CoreStatus] that never touches the platform channel.
class FakeCoreStatusNotifier extends CoreStatusNotifier {
  FakeCoreStatusNotifier(this.initial);

  final CoreStatus initial;

  @override
  CoreStatus build() => initial;

  /// Drives a transition, so tests can watch what the page does when the core
  /// goes away underneath it.
  void emit(CoreStatus next) => state = next;
}

/// [AppConfig] held in memory; [update] never reaches a file.
class FakeAppConfigNotifier extends AppConfigNotifier {
  FakeAppConfigNotifier(this.initial, {this.failWrites = false});

  final AppConfig initial;

  /// Makes [update] throw, for the "settings write failed" path.
  final bool failWrites;

  @override
  AppConfig build() => initial;

  @override
  Future<AppConfig> update(AppConfig Function(AppConfig current) updater) async {
    if (failWrites) throw StateError('write refused');
    state = updater(state);
    return state;
  }
}

/// A fixed log buffer.
class FakeLogsNotifier extends LogsNotifier {
  FakeLogsNotifier(this.initial);

  final List<LogLine> initial;

  @override
  List<LogLine> build() => initial;

  /// Appends as if a line had arrived on the socket.
  void emit(LogLine line) => state = <LogLine>[...state, line];
}

/// Records what the page asked the tunnel to do.
class RecordingCoreController implements CoreController {
  final List<String> closedIds = <String>[];
  int closeAllCalls = 0;

  /// When set, every call throws it.
  Object? failure;

  @override
  Future<void> closeConnection(String id) async {
    if (failure != null) throw failure!;
    closedIds.add(id);
  }

  @override
  Future<void> closeAllConnections() async {
    if (failure != null) throw failure!;
    closeAllCalls++;
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reloadProfile(String profileId) async {}

  @override
  Future<void> setMode(OutboundMode mode) async {}

  @override
  Future<void> selectProxy(String group, String node) async {}

  @override
  Future<int?> testDelay(String node) async => null;

  @override
  Future<Map<String, int>> testGroupDelay(String group) async =>
      const <String, int>{};
}

/// A running core with no error, which is what most of these tests want.
final CoreStatus runningStatus = CoreStatus(
  state: CoreState.running,
  version: 'test',
  startedAt: DateTime.utc(2026, 7, 26, 12),
);

/// One connection, with sensible defaults so a test only states what it cares
/// about.
ConnectionInfo makeConnection({
  required String id,
  String host = 'example.com:443',
  String network = 'tcp',
  String rule = 'DomainSuffix',
  String rulePayload = 'example.com',
  List<String> chains = const <String>['PROXY'],
  int upload = 1024,
  int download = 2048,
  int uploadSpeed = 0,
  int downloadSpeed = 0,
  DateTime? start,
  String type = 'Tun',
  String sourceIp = '10.0.0.2',
  String destinationIp = '93.184.216.34',
  String process = 'com.example.app',
}) => ConnectionInfo(
  id: id,
  host: host,
  network: network,
  rule: rule,
  rulePayload: rulePayload,
  chains: chains,
  upload: upload,
  download: download,
  uploadSpeed: uploadSpeed,
  downloadSpeed: downloadSpeed,
  start: start ?? DateTime.utc(2026, 7, 26, 11, 59),
  type: type,
  sourceIp: sourceIp,
  destinationIp: destinationIp,
  process: process,
);
