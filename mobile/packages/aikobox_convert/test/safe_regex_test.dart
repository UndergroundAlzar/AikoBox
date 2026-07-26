/// Port of `src/main/core/singbox/safeRegex.test.ts`, extended.
///
/// The extra cases exist because this gate stands between a subscription
/// server's arbitrary text and a regex engine running over every node name.
library;

import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('safe Clash filter regex', () {
    test('supports common case-insensitive region filters', () {
      final RegExp? regex = compileSafeClashRegex('(?i)香港|hong kong|hk');
      expect(regex, isNotNull);
      expect(regex!.hasMatch('Premium HK 01'), isTrue);
    });

    test('rejects nested quantifiers, backreferences, lookarounds, and '
        'oversized patterns', () {
      expect(
        () => compileSafeClashRegexOrThrow(r'^(a+)+$'),
        throwsA(_message(contains('nested'))),
      );
      expect(
        () => compileSafeClashRegexOrThrow(r'(a.*)*'),
        throwsA(_message(contains('nested'))),
      );
      expect(
        () => compileSafeClashRegexOrThrow(r'(a)\1'),
        throwsA(_message(contains('backreferences'))),
      );
      expect(
        () => compileSafeClashRegexOrThrow('a(?=b)'),
        throwsA(_message(contains('lookarounds'))),
      );
      expect(
        () => compileSafeClashRegexOrThrow('a' * 257),
        throwsA(_message(contains('1-256'))),
      );
    });

    test('the nullable wrapper never throws', () {
      for (final String pattern in <String>[
        r'^(a+)+$',
        r'(a)\1',
        'a(?=b)',
        'a' * 257,
        '',
        '(?i)',
        '(unbalanced',
        'unbalanced)',
        '[unterminated',
        r'a{2}{3}',
        r'\',
      ]) {
        expect(
          compileSafeClashRegex(pattern),
          isNull,
          reason: 'pattern "$pattern" should be refused, not compiled',
        );
      }
    });

    test('accepts the shapes real airport filters use', () {
      const List<String> accepted = <String>[
        '^HK',
        r'香港|台湾|日本',
        r'(?i)(hk|tw|jp)',
        r'\d+x',
        r'[A-Z]{2}-\d{2}',
        r'^(?:Premium|Standard)\s',
        r'.*Trial.*',
        r'实验|Experimental',
        r'^(?!)',
      ];
      for (final String pattern in accepted.take(accepted.length - 1)) {
        expect(
          compileSafeClashRegex(pattern),
          isNotNull,
          reason: 'pattern "$pattern" should compile',
        );
      }
      // the last one is a lookahead and must still be refused
      expect(compileSafeClashRegex(accepted.last), isNull);
    });

    test('a bounded quantifier counts as a quantifier', () {
      expect(compileSafeClashRegex(r'a{2,4}'), isNotNull);
      expect(compileSafeClashRegex(r'(a{2,4})+'), isNull);
      // `{` that is not a quantifier is just a literal
      expect(compileSafeClashRegex(r'a{b'), isNotNull);
    });

    test('a quantifier inside a character class is literal', () {
      expect(compileSafeClashRegex(r'[+*?]+'), isNotNull);
      expect(compileSafeClashRegex(r'[)(]'), isNotNull);
    });

    test('escapes are honoured on both sides of the check', () {
      // The `+` inside the group is a literal, so the group carries no
      // quantifier and the outer `+` is not nesting.
      expect(compileSafeClashRegex(r'(a\+)+'), isNotNull);
      // Escaped parentheses are literals, so there is no group to nest into:
      // this is `a+` followed by one-or-more `)`, which backtracks linearly.
      expect(compileSafeClashRegex(r'\(a+\)+'), isNotNull);
      // ...but a real group around a quantifier still is.
      expect(compileSafeClashRegex(r'(a\+b+)+'), isNull);
    });

    test('non-capturing groups are allowed, other special groups are not', () {
      expect(compileSafeClashRegex('(?:ab)c'), isNotNull);
      expect(compileSafeClashRegex('(?<name>ab)'), isNull);
      expect(compileSafeClashRegex('(?!ab)'), isNull);
      expect(compileSafeClashRegex('(?<=ab)c'), isNull);
    });

    test('the (?i) prefix only applies at the start', () {
      expect(compileSafeClashRegex('(?i)hk')!.hasMatch('HK'), isTrue);
      // mid-pattern (?i) is a special group and is refused
      expect(compileSafeClashRegex('hk(?i)'), isNull);
    });

    test('a 256-character pattern is the boundary', () {
      expect(compileSafeClashRegex('a' * 256), isNotNull);
      expect(compileSafeClashRegex('a' * 257), isNull);
      // the (?i) prefix is not counted against the budget
      expect(compileSafeClashRegex('(?i)${'a' * 256}'), isNotNull);
    });

    test('a refused filter surfaces as a group error, not a crash', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'a',
              'type': 'socks5',
              'server': '127.0.0.1',
              'port': 1080,
            },
          ],
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Bad',
              'type': 'select',
              'include-all': true,
              'filter': r'^(a+)+$',
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(
        joined(result.errors),
        matches(RegExp('unsafe or invalid filter')),
      );
      // and the group still ends up structurally valid
      expect(strings(outbound(result.config, 'Bad')['outbounds']), isNotEmpty);
    });
  });
}

Matcher _message(Matcher inner) => isA<ClashRegexException>().having(
  (ClashRegexException e) => e.message,
  'message',
  inner,
);
