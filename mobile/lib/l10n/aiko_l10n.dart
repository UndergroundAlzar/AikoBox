/// AikoBox localisation.
///
/// Flat dotted keys loaded from `assets/locales/<tag>.json`, with per-key
/// fallback to `en-US`. There is no code generation here on purpose: the key
/// set is data, and a generated Dart file that drifts out of step with the
/// JSON is worse than a `t('...')` call that is checked by a test.
///
/// Wiring (do this once, in the app's root widget):
///
/// ```dart
/// void main() async {
///   await AikoL10n.ensureInitialized();
///   runApp(const ProviderScope(child: AikoApp()));
/// }
///
/// // inside build():
/// MaterialApp(
///   locale: ref.watch(activeLocaleProvider),          // null => follow system
///   supportedLocales: AikoL10n.supportedLocales,
///   localizationsDelegates: AikoL10n.localizationsDelegates,
///   ...
/// )
/// ```
///
/// Usage in widgets — this is the one blessed form:
///
/// ```dart
/// Text(context.l10n.t('dashboard.title'))
/// Text(context.l10n.t('profiles.switchSuccess', args: {'name': profile.name}))
/// Text(context.l10n.plural('plural.connections', count))
/// ```
///
/// `AikoL10n.of(context)` is the same object if you need it without a
/// `BuildContext` extension.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The locale every other locale falls back to, key by key.
const String kBaseLocaleTag = 'en-US';

/// Directory the JSON bundles live in, relative to the package root.
const String kLocaleAssetDir = 'assets/locales';

/// CLDR plural categories. Only the ones the shipped locales can select are
/// modelled; `zero` and `two` are unused by en/zh/ru/fa.
enum PluralCategory { one, few, many, other }

/// One shipped locale.
@immutable
class AikoLocaleInfo {
  const AikoLocaleInfo({
    required this.tag,
    required this.languageCode,
    required this.countryCode,
    required this.nativeName,
    required this.englishName,
    required this.textDirection,
  });

  /// BCP-47-ish tag as used for the asset file name, e.g. `zh-CN`.
  final String tag;
  final String languageCode;
  final String countryCode;

  /// Name of the language written in that language — what the picker shows.
  final String nativeName;
  final String englishName;

  /// Reading direction for this locale. `fa-IR` is the only RTL one shipped.
  final TextDirection textDirection;

  Locale get locale => Locale(languageCode, countryCode);

  bool get isRtl => textDirection == TextDirection.rtl;

  /// Asset path of this locale's JSON bundle.
  String get assetPath => '$kLocaleAssetDir/$tag.json';

  @override
  String toString() => 'AikoLocaleInfo($tag)';
}

/// Every locale AikoBox ships, in the order the language picker should show
/// them. Mirrors `src/renderer/src/locales/` on the desktop app.
const List<AikoLocaleInfo> kAikoLocales = <AikoLocaleInfo>[
  AikoLocaleInfo(
    tag: 'zh-CN',
    languageCode: 'zh',
    countryCode: 'CN',
    nativeName: '简体中文',
    englishName: 'Chinese (Simplified)',
    textDirection: TextDirection.ltr,
  ),
  AikoLocaleInfo(
    tag: 'en-US',
    languageCode: 'en',
    countryCode: 'US',
    nativeName: 'English',
    englishName: 'English',
    textDirection: TextDirection.ltr,
  ),
  AikoLocaleInfo(
    tag: 'zh-TW',
    languageCode: 'zh',
    countryCode: 'TW',
    nativeName: '繁體中文',
    englishName: 'Chinese (Traditional)',
    textDirection: TextDirection.ltr,
  ),
  AikoLocaleInfo(
    tag: 'ru-RU',
    languageCode: 'ru',
    countryCode: 'RU',
    nativeName: 'Русский',
    englishName: 'Russian',
    textDirection: TextDirection.ltr,
  ),
  AikoLocaleInfo(
    tag: 'fa-IR',
    languageCode: 'fa',
    countryCode: 'IR',
    nativeName: 'فارسی',
    englishName: 'Persian',
    textDirection: TextDirection.rtl,
  ),
];

/// A resolved translation bundle for one locale.
class AikoL10n {
  AikoL10n._(this.info, this._strings, this._fallback);

  /// Builds an instance straight from maps. Tests only — the app goes through
  /// [AikoL10n.load] so it exercises the real asset path.
  @visibleForTesting
  factory AikoL10n.fromMaps(
    AikoLocaleInfo info,
    Map<String, String> strings, {
    Map<String, String> fallback = const <String, String>{},
  }) {
    return AikoL10n._(
      info,
      Map<String, String>.unmodifiable(strings),
      Map<String, String>.unmodifiable(fallback),
    );
  }

  final AikoLocaleInfo info;
  final Map<String, String> _strings;
  final Map<String, String> _fallback;

  /// Called whenever a key resolves to nothing at all, in either bundle.
  /// Left null by default so this file never prints; wire it up in `main()` if
  /// you want missing keys in the log.
  static void Function(String key, String localeTag)? onMissingKey;

  static final Map<String, Map<String, String>> _bundles =
      <String, Map<String, String>>{};

  static bool _bootstrapped = false;
  static String? _bootstrappedTag;

  // ---------------------------------------------------------------- locales

  static List<Locale> get supportedLocales =>
      kAikoLocales.map((AikoLocaleInfo e) => e.locale).toList(growable: false);

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        AikoL10nDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ];

  static bool isSupportedTag(String tag) =>
      kAikoLocales.any((AikoLocaleInfo e) => e.tag == tag);

  static AikoLocaleInfo infoForTag(String tag) => kAikoLocales.firstWhere(
    (AikoLocaleInfo e) => e.tag == tag,
    orElse: () => infoForTag(kBaseLocaleTag),
  );

  /// Maps an arbitrary platform [Locale] onto one of the shipped tags.
  ///
  /// Exact language+country wins; then language+script (`zh-Hant` -> `zh-TW`);
  /// then language alone; otherwise [kBaseLocaleTag].
  static String resolveTag(Locale locale) {
    final String lang = locale.languageCode.toLowerCase();
    final String? country = locale.countryCode?.toUpperCase();
    final String? script = locale.scriptCode?.toLowerCase();

    for (final AikoLocaleInfo e in kAikoLocales) {
      if (e.languageCode == lang && e.countryCode == country) return e.tag;
    }
    if (lang == 'zh') {
      if (script == 'hant') return 'zh-TW';
      if (script == 'hans') return 'zh-CN';
      // Traditional-script regions that do not carry a script subtag.
      if (country == 'HK' || country == 'MO') return 'zh-TW';
      return 'zh-CN';
    }
    for (final AikoLocaleInfo e in kAikoLocales) {
      if (e.languageCode == lang) return e.tag;
    }
    return kBaseLocaleTag;
  }

  static AikoLocaleInfo infoForLocale(Locale locale) =>
      infoForTag(resolveTag(locale));

  /// Reading direction for [locale] after resolution. The app should feed this
  /// into `Directionality` / `MaterialApp` so `fa-IR` renders right-to-left.
  static TextDirection textDirectionOf(Locale locale) =>
      infoForLocale(locale).textDirection;

  // ------------------------------------------------------------- bootstrap

  /// True once [ensureInitialized] has run.
  static bool get isBootstrapped => _bootstrapped;

  /// The persisted locale tag read during [ensureInitialized]; null means
  /// "follow the system".
  static String? get bootstrappedLocaleTag => _bootstrappedTag;

  /// Reads the persisted language choice and pre-warms the JSON bundles so the
  /// first frame is not a flash of untranslated text. Safe to call twice.
  static Future<void> ensureInitialized({AssetBundle? bundle}) async {
    WidgetsFlutterBinding.ensureInitialized();
    final AssetBundle b = bundle ?? rootBundle;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(LocaleSettingNotifier.prefsKey);
    _bootstrappedTag = (stored != null && isSupportedTag(stored))
        ? stored
        : null;
    _bootstrapped = true;

    await _bundleFor(kBaseLocaleTag, b);
    final String active =
        _bootstrappedTag ?? resolveTag(PlatformDispatcher.instance.locale);
    if (active != kBaseLocaleTag) {
      await _bundleFor(active, b);
    }
  }

  /// Drops the bundle cache and the bootstrap flag.
  @visibleForTesting
  static void resetForTests() {
    _bundles.clear();
    _bootstrapped = false;
    _bootstrappedTag = null;
    onMissingKey = null;
  }

  // ---------------------------------------------------------------- loading

  static Future<Map<String, String>> _bundleFor(
    String tag,
    AssetBundle bundle,
  ) async {
    final Map<String, String>? cached = _bundles[tag];
    if (cached != null) return cached;

    Map<String, String> parsed;
    try {
      final String raw = await bundle.loadString('$kLocaleAssetDir/$tag.json');
      parsed = flattenLocaleJson(jsonDecode(raw));
    } catch (_) {
      // A missing base bundle is a packaging bug and must be loud; a missing
      // translation is survivable because every key falls back to en-US.
      if (tag == kBaseLocaleTag) rethrow;
      parsed = const <String, String>{};
    }
    final Map<String, String> frozen = Map<String, String>.unmodifiable(parsed);
    _bundles[tag] = frozen;
    return frozen;
  }

  /// Accepts either the flat `{"a.b": "x"}` shape this app ships or a nested
  /// `{"a": {"b": "x"}}` one, and always returns flat dotted keys.
  static Map<String, String> flattenLocaleJson(Object? decoded) {
    final Map<String, String> out = <String, String>{};
    void walk(String prefix, Object? node) {
      if (node is Map) {
        node.forEach((Object? k, Object? v) {
          final String key = prefix.isEmpty ? '$k' : '$prefix.$k';
          walk(key, v);
        });
      } else if (node is List) {
        for (int i = 0; i < node.length; i++) {
          walk('$prefix.$i', node[i]);
        }
      } else if (node != null && prefix.isNotEmpty) {
        out[prefix] = '$node';
      }
    }

    walk('', decoded);
    return out;
  }

  /// Loads (or reuses) the bundle for [locale] plus the en-US fallback.
  static Future<AikoL10n> load(Locale locale, {AssetBundle? bundle}) async {
    final AssetBundle b = bundle ?? rootBundle;
    final String tag = resolveTag(locale);
    final Map<String, String> fallback = await _bundleFor(kBaseLocaleTag, b);
    final Map<String, String> strings = tag == kBaseLocaleTag
        ? fallback
        : await _bundleFor(tag, b);
    return AikoL10n._(infoForTag(tag), strings, fallback);
  }

  // ---------------------------------------------------------------- lookup

  static AikoL10n of(BuildContext context) {
    final AikoL10n? found = maybeOf(context);
    if (found != null) return found;
    throw FlutterError.fromParts(<DiagnosticsNode>[
      ErrorSummary('No AikoL10n found above this widget.'),
      ErrorDescription(
        'AikoL10n.of() was called with a context that does not sit under a '
        'Localizations widget carrying AikoL10nDelegate.',
      ),
      ErrorHint(
        'Add AikoL10n.localizationsDelegates and AikoL10n.supportedLocales to '
        'your MaterialApp, or wrap the widget under test in one.',
      ),
    ]);
  }

  static AikoL10n? maybeOf(BuildContext context) =>
      Localizations.of<AikoL10n>(context, AikoL10n);

  String get localeTag => info.tag;

  TextDirection get textDirection => info.textDirection;

  bool get isRtl => info.isRtl;

  /// True when [key] exists in this locale or in the fallback.
  bool has(String key) =>
      _strings.containsKey(key) || _fallback.containsKey(key);

  /// True when [key] exists in this locale specifically (no fallback).
  bool hasOwn(String key) => _strings.containsKey(key);

  /// All keys visible through this bundle, including fallback-only ones.
  Iterable<String> get keys =>
      <String>{..._strings.keys, ..._fallback.keys}.toList(growable: false);

  /// Resolves [key], falling back to en-US for that single key, then to the
  /// key itself so a missing string is visible rather than silently blank.
  ///
  /// `{name}` and `{{name}}` in the value are replaced from [args]. Tokens with
  /// no matching argument are left exactly as they are.
  String t(String key, {Map<String, Object?>? args}) {
    final String? raw = _strings[key] ?? _fallback[key];
    if (raw == null) {
      onMissingKey?.call(key, info.tag);
      return key;
    }
    return interpolate(raw, args);
  }

  /// Plural form of [key] for [count].
  ///
  /// Looks for `<key>_<category>`, then `<key>_other`, then `<key>` — first in
  /// this locale, then in en-US, so a locale that omits `_few` uses its own
  /// `_other` rather than an English string. `{count}` is always available as
  /// an argument.
  String plural(String key, int count, {Map<String, Object?>? args}) {
    final PluralCategory category = pluralCategory(info.languageCode, count);
    final List<String> candidates = <String>[
      '${key}_${category.name}',
      '${key}_other',
      key,
    ];

    String? raw;
    for (final String candidate in candidates) {
      raw = _strings[candidate];
      if (raw != null) break;
    }
    if (raw == null) {
      for (final String candidate in candidates) {
        raw = _fallback[candidate];
        if (raw != null) break;
      }
    }
    if (raw == null) {
      onMissingKey?.call(candidates.first, info.tag);
      return candidates.first;
    }

    return interpolate(raw, <String, Object?>{'count': count, ...?args});
  }

  // --------------------------------------------------------- interpolation

  static final RegExp _placeholder = RegExp(r'\{\{(\w+)\}\}|\{(\w+)\}');

  /// Substitutes `{name}` / `{{name}}` tokens from [args]. Unknown tokens are
  /// preserved verbatim, which makes a wiring mistake obvious in the UI instead
  /// of producing a plausible-looking but wrong sentence.
  static String interpolate(String template, Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return template;
    if (!template.contains('{')) return template;
    return template.replaceAllMapped(_placeholder, (Match m) {
      final String name = (m.group(1) ?? m.group(2))!;
      if (!args.containsKey(name)) return m.group(0)!;
      final Object? value = args[name];
      return value == null ? '' : '$value';
    });
  }

  /// CLDR plural category for [languageCode] and [count].
  ///
  /// Implemented directly rather than pulled from `intl` so the behaviour is
  /// pinned and testable for exactly the five locales that ship.
  static PluralCategory pluralCategory(String languageCode, int count) {
    final int n = count.abs();
    switch (languageCode) {
      // No grammatical plural.
      case 'zh':
      case 'ja':
      case 'ko':
      case 'th':
      case 'vi':
      case 'id':
      case 'ms':
        return PluralCategory.other;
      // East Slavic: one / few / many.
      case 'ru':
      case 'uk':
      case 'be':
        final int mod10 = n % 10;
        final int mod100 = n % 100;
        if (mod10 == 1 && mod100 != 11) return PluralCategory.one;
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return PluralCategory.few;
        }
        return PluralCategory.many;
      // Persian and Hindi treat 0 as singular.
      case 'fa':
      case 'hi':
        return n <= 1 ? PluralCategory.one : PluralCategory.other;
      default:
        return n == 1 ? PluralCategory.one : PluralCategory.other;
    }
  }
}

/// The `LocalizationsDelegate` that installs [AikoL10n] into the widget tree.
class AikoL10nDelegate extends LocalizationsDelegate<AikoL10n> {
  const AikoL10nDelegate();

  @override
  bool isSupported(Locale locale) => kAikoLocales.any(
    (AikoLocaleInfo e) => e.languageCode == locale.languageCode,
  );

  @override
  Future<AikoL10n> load(Locale locale) => AikoL10n.load(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AikoL10n> old) => false;
}

/// `context.l10n.t('dashboard.title')`.
extension AikoL10nContext on BuildContext {
  AikoL10n get l10n => AikoL10n.of(this);

  /// Shorthand for `l10n.t(key)`.
  String tr(String key, {Map<String, Object?>? args}) =>
      AikoL10n.of(this).t(key, args: args);
}

// ---------------------------------------------------------------- Riverpod

/// The persisted language choice. `null` means "follow the system locale".
class LocaleSettingNotifier extends Notifier<String?> {
  static const String prefsKey = 'aikobox.locale';

  bool _disposed = false;

  @override
  String? build() {
    ref.onDispose(() => _disposed = true);
    if (AikoL10n.isBootstrapped) return AikoL10n.bootstrappedLocaleTag;
    // main() skipped AikoL10n.ensureInitialized(); read the preference late so
    // the choice is still honoured, just one frame behind.
    unawaited(_readLate());
    return null;
  }

  Future<void> _readLate() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(prefsKey);
    if (_disposed || stored == null || !AikoL10n.isSupportedTag(stored)) return;
    if (state == null) state = stored;
  }

  /// Switches the app language. Pass null to follow the system locale.
  Future<void> setLocaleTag(String? tag) async {
    if (tag != null && !AikoL10n.isSupportedTag(tag)) {
      throw ArgumentError.value(tag, 'tag', 'not a shipped AikoBox locale');
    }
    if (!_disposed) state = tag;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (tag == null) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, tag);
    }
  }
}

/// The stored locale tag, or null for "follow the system".
final NotifierProvider<LocaleSettingNotifier, String?> localeSettingProvider =
    NotifierProvider<LocaleSettingNotifier, String?>(LocaleSettingNotifier.new);

/// Feed straight into `MaterialApp.locale`. Null lets Flutter resolve against
/// the device locale.
final Provider<Locale?> activeLocaleProvider = Provider<Locale?>((Ref ref) {
  final String? tag = ref.watch(localeSettingProvider);
  return tag == null ? null : AikoL10n.infoForTag(tag).locale;
});

/// The locale actually in effect, system resolution included.
final Provider<AikoLocaleInfo> activeLocaleInfoProvider =
    Provider<AikoLocaleInfo>((Ref ref) {
      final String? tag = ref.watch(localeSettingProvider);
      if (tag != null) return AikoL10n.infoForTag(tag);
      return AikoL10n.infoForLocale(PlatformDispatcher.instance.locale);
    });

/// Reading direction of the active locale — `rtl` for `fa-IR`.
final Provider<TextDirection> textDirectionProvider = Provider<TextDirection>((
  Ref ref,
) {
  return ref.watch(activeLocaleInfoProvider).textDirection;
});
