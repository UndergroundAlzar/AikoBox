import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` runs with the package root as the working directory, but be
/// forgiving if a runner picks `test/` instead.
Directory _localesDir() {
  Directory dir = Directory.current;
  for (int i = 0; i < 4; i++) {
    final Directory candidate = Directory('${dir.path}/assets/locales');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  throw StateError('assets/locales not found from ${Directory.current.path}');
}

Map<String, String> _readLocale(String tag) {
  final File file = File('${_localesDir().path}/$tag.json');
  final Object? decoded = jsonDecode(file.readAsStringSync());
  expect(decoded, isA<Map<String, dynamic>>(),
      reason: '$tag.json must be a JSON object');
  final Map<String, dynamic> map = decoded! as Map<String, dynamic>;
  return map.map((String k, dynamic v) {
    expect(v, isA<String>(), reason: '$tag.json: "$k" must be a string');
    return MapEntry<String, String>(k, v as String);
  });
}

final RegExp _placeholderRe = RegExp(r'\{\{(\w+)\}\}|\{(\w+)\}');

Set<String> _placeholders(String value) => _placeholderRe
    .allMatches(value)
    .map((Match m) => (m.group(1) ?? m.group(2))!)
    .toSet();

/// Serves the real JSON files off disk so the loader can be exercised without
/// a packaged asset manifest.
///
/// Reads are synchronous on purpose: `testWidgets` runs inside a `FakeAsync`
/// zone where real file IO never completes, so an `async` bundle would deadlock
/// the widget test.
class _DiskBundle extends CachingAssetBundle {
  _DiskBundle(this.root);

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

  // AssetBundle.loadString hands anything over 50 KB to compute(), which spawns
  // an isolate that FakeAsync cannot drive. ru-RU.json is already past that, so
  // decode here instead of inheriting the size heuristic.
  @override
  Future<String> loadString(String key, {bool cache = true}) {
    final File file = _fileFor(key);
    if (!file.existsSync()) {
      return Future<String>.error(FlutterError('asset not found: $key'));
    }
    return SynchronousFuture<String>(file.readAsStringSync(encoding: utf8));
  }
}

void main() {
  final List<String> tags =
      kAikoLocales.map((AikoLocaleInfo e) => e.tag).toList(growable: false);

  group('locale assets', () {
    late Map<String, Map<String, String>> bundles;

    setUpAll(() {
      bundles = <String, Map<String, String>>{
        for (final String tag in tags) tag: _readLocale(tag),
      };
    });

    test('every shipped locale has an asset and there are no stray files', () {
      final List<String> onDisk = _localesDir()
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .where((String name) => name.endsWith('.json'))
          .map((String name) => name.substring(0, name.length - 5))
          .toList()
        ..sort();
      expect(onDisk, equals(<String>[...tags]..sort()));
    });

    test('en-US is the base locale and is not empty', () {
      expect(kBaseLocaleTag, 'en-US');
      expect(bundles[kBaseLocaleTag]!.length, greaterThan(500));
    });

    test('every non-base locale has exactly the en-US key set', () {
      final Set<String> base = bundles[kBaseLocaleTag]!.keys.toSet();
      for (final String tag in tags) {
        if (tag == kBaseLocaleTag) continue;
        final Set<String> keys = bundles[tag]!.keys.toSet();
        final List<String> missing = base.difference(keys).toList()..sort();
        final List<String> extra = keys.difference(base).toList()..sort();
        expect(missing, isEmpty, reason: '$tag is missing keys: $missing');
        expect(extra, isEmpty,
            reason: '$tag has keys en-US does not: $extra');
      }
    });

    test('no value is empty or whitespace only', () {
      for (final String tag in tags) {
        bundles[tag]!.forEach((String key, String value) {
          expect(value.trim(), isNotEmpty,
              reason: '$tag: "$key" has an empty value');
        });
      }
    });

    test('placeholders match en-US in every locale', () {
      final Map<String, String> base = bundles[kBaseLocaleTag]!;
      for (final String tag in tags) {
        if (tag == kBaseLocaleTag) continue;
        bundles[tag]!.forEach((String key, String value) {
          expect(_placeholders(value), equals(_placeholders(base[key]!)),
              reason: '$tag: "$key" placeholders differ from en-US');
        });
      }
    });

    test('no duplicate keys survive in the raw JSON text', () {
      final RegExp keyLine = RegExp(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', multiLine: true);
      for (final String tag in tags) {
        final String raw =
            File('${_localesDir().path}/$tag.json').readAsStringSync();
        final List<String> keys = keyLine
            .allMatches(raw)
            .map((Match m) => m.group(1)!)
            .toList(growable: false);
        expect(keys.length, bundles[tag]!.length,
            reason: '$tag.json contains duplicate keys');
      }
    });

    test('every plural base carries all four categories', () {
      final Set<String> base = bundles[kBaseLocaleTag]!.keys.toSet();
      final Set<String> pluralBases = base
          .where((String k) => k.startsWith('plural.'))
          .map((String k) => k.substring(0, k.lastIndexOf('_')))
          .toSet();
      expect(pluralBases, isNotEmpty);
      for (final String stem in pluralBases) {
        for (final PluralCategory c in PluralCategory.values) {
          expect(base, contains('${stem}_${c.name}'));
        }
      }
    });

    test('the Android-only surfaces are covered', () {
      final Set<String> base = bundles[kBaseLocaleTag]!.keys.toSet();
      for (final String key in <String>[
        'vpn.permission.title',
        'vpn.permission.denied.message',
        'vpn.alwaysOn.title',
        'vpn.alwaysOn.blockConnections',
        'vpn.revoked.title',
        'perApp.title',
        'perApp.mode.allowlist',
        'perApp.mode.denylist',
        'notification.channel.service.name',
        'notification.running.body',
        'notification.permission.message',
        'tile.hint.title',
        'tile.state.on',
        'battery.title',
        'battery.request',
        'nav.dashboard',
        'nav.tools',
        'dashboard.title',
        'about.title',
        'theme.title',
      ]) {
        expect(base, contains(key), reason: 'missing Android key $key');
      }
    });

    test('zh-CN keeps the desktop terminology', () {
      final Map<String, String> zh = bundles['zh-CN']!;
      expect(zh['profiles.title'], '订阅管理');
      expect(zh['override.title'], '覆写');
      expect(zh['sider.cards.outbound.title'], '出站模式');
      expect(zh['outbound.modes.rule'], '规则');
      expect(zh['outbound.modes.global'], '全局');
      expect(zh['outbound.modes.direct'], '直连');
      expect(zh['mihomo.title'], '内核设置');
      expect(zh['perApp.title'], '分应用代理');
    });
  });

  group('AikoL10n loader', () {
    late _DiskBundle bundle;

    setUp(() {
      AikoL10n.resetForTests();
      bundle = _DiskBundle(_localesDir().path);
    });

    tearDown(AikoL10n.resetForTests);

    test('loads a locale and reports its direction', () async {
      final AikoL10n fa =
          await AikoL10n.load(const Locale('fa', 'IR'), bundle: bundle);
      expect(fa.localeTag, 'fa-IR');
      expect(fa.textDirection, TextDirection.rtl);
      expect(fa.isRtl, isTrue);
      expect(fa.t('nav.dashboard'), 'داشبورد');

      final AikoL10n zh =
          await AikoL10n.load(const Locale('zh', 'CN'), bundle: bundle);
      expect(zh.textDirection, TextDirection.ltr);
      expect(zh.t('perApp.title'), '分应用代理');
    });

    test('interpolates named placeholders', () async {
      final AikoL10n en =
          await AikoL10n.load(const Locale('en', 'US'), bundle: bundle);
      expect(
        en.t('profiles.switchSuccess', args: <String, Object?>{'name': 'HK 01'}),
        'Switched to “HK 01”',
      );
      // Unknown tokens survive untouched instead of turning into a plausible
      // but wrong sentence.
      expect(en.t('profiles.switchSuccess'), contains('{name}'));
    });

    test('pluralises per locale', () async {
      final AikoL10n en =
          await AikoL10n.load(const Locale('en', 'US'), bundle: bundle);
      expect(en.plural('plural.days', 1), '1 day');
      expect(en.plural('plural.days', 3), '3 days');

      final AikoL10n ru =
          await AikoL10n.load(const Locale('ru', 'RU'), bundle: bundle);
      expect(ru.plural('plural.days', 1), '1 день');
      expect(ru.plural('plural.days', 3), '3 дня');
      expect(ru.plural('plural.days', 11), '11 дней');

      final AikoL10n zh =
          await AikoL10n.load(const Locale('zh', 'CN'), bundle: bundle);
      expect(zh.plural('plural.days', 1), '1 天');
      expect(zh.plural('plural.days', 7), '7 天');
    });

    test('a locale with no bundle still resolves through en-US', () async {
      // 'de' is not shipped, so resolveTag lands on the base locale.
      final AikoL10n de =
          await AikoL10n.load(const Locale('de', 'DE'), bundle: bundle);
      expect(de.localeTag, kBaseLocaleTag);
      expect(de.t('nav.dashboard'), 'Dashboard');
    });
  });

  group('AikoL10n pure helpers', () {
    test('resolveTag maps platform locales onto shipped tags', () {
      expect(AikoL10n.resolveTag(const Locale('zh', 'CN')), 'zh-CN');
      expect(AikoL10n.resolveTag(const Locale('zh', 'TW')), 'zh-TW');
      expect(AikoL10n.resolveTag(const Locale('zh', 'HK')), 'zh-TW');
      expect(AikoL10n.resolveTag(const Locale('zh')), 'zh-CN');
      expect(
        AikoL10n.resolveTag(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        'zh-TW',
      );
      expect(AikoL10n.resolveTag(const Locale('en', 'GB')), 'en-US');
      expect(AikoL10n.resolveTag(const Locale('ru')), 'ru-RU');
      expect(AikoL10n.resolveTag(const Locale('fa')), 'fa-IR');
      expect(AikoL10n.resolveTag(const Locale('de', 'DE')), 'en-US');
    });

    test('textDirectionOf marks only fa-IR as RTL', () {
      for (final AikoLocaleInfo info in kAikoLocales) {
        expect(
          AikoL10n.textDirectionOf(info.locale),
          info.tag == 'fa-IR' ? TextDirection.rtl : TextDirection.ltr,
          reason: info.tag,
        );
      }
    });

    test('plural categories follow CLDR for the shipped languages', () {
      expect(AikoL10n.pluralCategory('en', 1), PluralCategory.one);
      expect(AikoL10n.pluralCategory('en', 0), PluralCategory.other);
      expect(AikoL10n.pluralCategory('en', 2), PluralCategory.other);

      expect(AikoL10n.pluralCategory('zh', 1), PluralCategory.other);
      expect(AikoL10n.pluralCategory('zh', 5), PluralCategory.other);

      expect(AikoL10n.pluralCategory('ru', 1), PluralCategory.one);
      expect(AikoL10n.pluralCategory('ru', 21), PluralCategory.one);
      expect(AikoL10n.pluralCategory('ru', 11), PluralCategory.many);
      expect(AikoL10n.pluralCategory('ru', 3), PluralCategory.few);
      expect(AikoL10n.pluralCategory('ru', 24), PluralCategory.few);
      expect(AikoL10n.pluralCategory('ru', 14), PluralCategory.many);
      expect(AikoL10n.pluralCategory('ru', 5), PluralCategory.many);

      expect(AikoL10n.pluralCategory('fa', 0), PluralCategory.one);
      expect(AikoL10n.pluralCategory('fa', 1), PluralCategory.one);
      expect(AikoL10n.pluralCategory('fa', 2), PluralCategory.other);
    });

    test('interpolate accepts both brace styles and leaves unknowns alone', () {
      expect(
        AikoL10n.interpolate('a {one} b {{two}} c {three}',
            <String, Object?>{'one': 1, 'two': 2}),
        'a 1 b 2 c {three}',
      );
      expect(AikoL10n.interpolate('no tokens', <String, Object?>{'x': 1}),
          'no tokens');
    });

    test('flattenLocaleJson handles nested maps as well as flat ones', () {
      expect(
        AikoL10n.flattenLocaleJson(<String, Object?>{'a.b': 'x'}),
        <String, String>{'a.b': 'x'},
      );
      expect(
        AikoL10n.flattenLocaleJson(<String, Object?>{
          'a': <String, Object?>{'b': 'x', 'c': 2},
        }),
        <String, String>{'a.b': 'x', 'a.c': '2'},
      );
    });

    test('per-key fallback to en-US, then to the key itself', () {
      final AikoL10n l10n = AikoL10n.fromMaps(
        AikoL10n.infoForTag('ru-RU'),
        <String, String>{'a': 'ру'},
        fallback: <String, String>{'a': 'en a', 'b': 'en b'},
      );
      expect(l10n.t('a'), 'ру');
      expect(l10n.t('b'), 'en b');
      expect(l10n.t('c'), 'c');
      expect(l10n.has('b'), isTrue);
      expect(l10n.hasOwn('b'), isFalse);

      final List<String> missed = <String>[];
      AikoL10n.onMissingKey = (String key, String tag) => missed.add(key);
      addTearDown(() => AikoL10n.onMissingKey = null);
      l10n.t('nope');
      expect(missed, <String>['nope']);
    });

    test('plural prefers the locale own _other over an English category', () {
      final AikoL10n ru = AikoL10n.fromMaps(
        AikoL10n.infoForTag('ru-RU'),
        <String, String>{'n_one': '{count} узел', 'n_other': '{count} узла'},
        fallback: <String, String>{
          'n_one': '{count} node',
          'n_few': '{count} nodes (en few)',
          'n_other': '{count} nodes',
        },
      );
      expect(ru.plural('n', 1), '1 узел');
      // 3 selects `few`, which ru does not define -> its own `_other`.
      expect(ru.plural('n', 3), '3 узла');
    });
  });

  group('BuildContext integration', () {
    testWidgets('context.l10n resolves through the delegate', (
      WidgetTester tester,
    ) async {
      AikoL10n.resetForTests();
      addTearDown(AikoL10n.resetForTests);
      // Prime the bundle cache from disk; the delegate then never touches
      // rootBundle, which has no asset manifest under `flutter test`.
      final _DiskBundle bundle = _DiskBundle(_localesDir().path);
      await AikoL10n.load(const Locale('zh', 'CN'), bundle: bundle);

      late String seen;
      late TextDirection direction;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AikoL10n.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            AikoL10nDelegate(),
          ],
          builder: (BuildContext context, Widget? child) {
            seen = context.l10n.t('nav.dashboard');
            direction = context.l10n.textDirection;
            return Text(seen, textDirection: TextDirection.ltr);
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(seen, '仪表盘');
      expect(direction, TextDirection.ltr);
      expect(find.text('仪表盘'), findsOneWidget);
    });
  });
}
