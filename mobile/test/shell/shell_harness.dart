import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Serves a fixed key->string map as `AikoL10n`, so a shell test asserts on
/// navigation rather than on translation quality. The real bundles are covered
/// by `test/l10n/locales_test.dart`.
class StubL10nDelegate extends LocalizationsDelegate<AikoL10n> {
  const StubL10nDelegate(this.strings, {this.tag = 'en-US'});

  final Map<String, String> strings;
  final String tag;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AikoL10n> load(Locale locale) => SynchronousFuture<AikoL10n>(
    AikoL10n.fromMaps(AikoL10n.infoForTag(tag), strings),
  );

  @override
  bool shouldReload(covariant LocalizationsDelegate<AikoL10n> old) => false;
}

/// The nav labels every shell test needs.
const Map<String, String> kStubNavStrings = <String, String>{
  'nav.dashboard': 'Dashboard',
  'nav.proxies': 'Proxies',
  'nav.profiles': 'Profiles',
  'nav.tools': 'Tools',
};

/// Mounts [child] under a real AikoBox theme, a stub `AikoL10n` and a
/// provider scope.
///
/// Pass [container] to supply overrides — `Override` is not exported from
/// `flutter_riverpod`, so it cannot be named in this signature, but a
/// `ProviderContainer(overrides: [...])` built at the call site infers fine.
Widget hostShell(
  Widget child, {
  Map<String, String> strings = kStubNavStrings,
  ProviderContainer? container,
  String tag = 'en-US',
}) {
  final Widget app = MaterialApp(
    theme: AikoTheme.light(),
    localizationsDelegates: <LocalizationsDelegate<dynamic>>[
      StubL10nDelegate(strings, tag: tag),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AikoL10n.supportedLocales,
    home: child,
  );

  return container == null
      ? ProviderScope(child: app)
      : UncontrolledProviderScope(container: container, child: app);
}
