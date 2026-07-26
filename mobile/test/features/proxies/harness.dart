/// Widget-test scaffolding for the proxies page.
///
/// The page's strings all come from `assets/locales/`, so a widget test needs a
/// real bundle above it. `flutter test` has no asset manifest, so the JSON is
/// served straight off disk and pre-loaded into [AikoL10n]'s cache before the
/// delegate ever asks `rootBundle` for it — the same trick `test/l10n` uses.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Directory _localesDir() {
  Directory dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidate = Directory('${dir.path}/assets/locales');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('assets/locales not found from ${Directory.current.path}');
}

/// Reads locale JSON synchronously.
///
/// Synchronous because `testWidgets` runs inside a fake-async zone where real
/// file IO never completes, and because `AssetBundle.loadString` hands anything
/// over 50 KB to `compute()`, which spawns an isolate that zone cannot drive.
class _DiskBundle extends CachingAssetBundle {
  _DiskBundle(this.root);

  final String root;

  File _fileFor(String key) => File('$root/${key.split('/').last}');

  @override
  Future<ByteData> load(String key) {
    final file = _fileFor(key);
    if (!file.existsSync()) {
      return Future<ByteData>.error(FlutterError('asset not found: $key'));
    }
    return SynchronousFuture<ByteData>(
      ByteData.sublistView(file.readAsBytesSync()),
    );
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    final file = _fileFor(key);
    if (!file.existsSync()) {
      return Future<String>.error(FlutterError('asset not found: $key'));
    }
    return SynchronousFuture<String>(file.readAsStringSync(encoding: utf8));
  }
}

/// Loads [locale] and the en-US fallback into the bundle cache. Call from
/// `setUp`, and pair it with `tearDown(AikoL10n.resetForTests)`.
Future<void> primeProxyL10n([Locale locale = const Locale('en', 'US')]) async {
  AikoL10n.resetForTests();
  await AikoL10n.load(locale, bundle: _DiskBundle(_localesDir().path));
}

/// Hosts [child] under the shipped theme and localisations.
Widget hostProxyWidget(
  Widget child, {
  Locale locale = const Locale('en', 'US'),
  Brightness brightness = Brightness.light,
  Size? size,
}) {
  final Widget body = size == null
      ? child
      : Center(
          child: SizedBox.fromSize(size: size, child: child),
        );

  return MaterialApp(
    theme: brightness == Brightness.dark ? AikoTheme.dark() : AikoTheme.light(),
    locale: locale,
    supportedLocales: AikoL10n.supportedLocales,
    localizationsDelegates: AikoL10n.localizationsDelegates,
    home: Scaffold(body: body),
  );
}

/// Hosts a whole page — one that brings its own `AikoScaffold`.
///
/// Wrap the result in a `ProviderScope` at the call site rather than passing
/// overrides through here: Riverpod 3 does not export the `Override` type, so
/// the list can only be written where its element type is inferred from
/// `ProviderScope.overrides`.
Widget hostProxyPage(
  Widget page, {
  Locale locale = const Locale('en', 'US'),
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: brightness == Brightness.dark ? AikoTheme.dark() : AikoTheme.light(),
  locale: locale,
  supportedLocales: AikoL10n.supportedLocales,
  localizationsDelegates: AikoL10n.localizationsDelegates,
  home: page,
);
