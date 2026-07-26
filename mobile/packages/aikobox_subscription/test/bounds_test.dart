/// `assertBoundedClashSubscription` is also called directly by the profile
/// store, after normalisation and after any later rewrite, so it is tested as
/// a standalone contract rather than only through the parser.
library;

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

Map<String, dynamic> clash({
  int proxies = 0,
  int providers = 0,
  int groups = 0,
  int rules = 0,
  List<dynamic>? rawRules,
}) => <String, dynamic>{
  'proxies': <dynamic>[
    for (var index = 0; index < proxies; index += 1)
      <String, dynamic>{'name': 'p$index', 'type': 'ss'},
  ],
  'proxy-providers': <String, dynamic>{
    for (var index = 0; index < providers; index += 1)
      'v$index': <String, dynamic>{'type': 'http'},
  },
  'proxy-groups': <dynamic>[
    for (var index = 0; index < groups; index += 1)
      <String, dynamic>{'name': 'g$index', 'type': 'select'},
  ],
  'rules': rawRules ?? List<String>.filled(rules, 'MATCH,DIRECT'),
};

Matcher throwsBounds(String fragment) => throwsA(
  isA<SubscriptionBoundsException>().having(
    (error) => error.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('assertBoundedClashSubscription', () {
    test('accepts a config sitting exactly on every cap', () {
      expect(
        () => assertBoundedClashSubscription(
          clash(
            proxies: kMaxSubscriptionProxies,
            providers: kMaxSubscriptionProviders,
            groups: kMaxSubscriptionGroups,
            rules: kMaxSubscriptionRules,
          ),
        ),
        returnsNormally,
      );
    });

    test('refuses one over each cap, naming the cap', () {
      expect(
        () => assertBoundedClashSubscription(
          clash(proxies: kMaxSubscriptionProxies + 1),
        ),
        throwsBounds('10000 proxy nodes'),
      );
      expect(
        () => assertBoundedClashSubscription(
          clash(providers: kMaxSubscriptionProviders + 1),
        ),
        throwsBounds('64 proxy providers'),
      );
      expect(
        () => assertBoundedClashSubscription(
          clash(groups: kMaxSubscriptionGroups + 1),
        ),
        throwsBounds('512 proxy groups'),
      );
      expect(
        () => assertBoundedClashSubscription(
          clash(rules: kMaxSubscriptionRules + 1),
        ),
        throwsBounds('50000 rules'),
      );
    });

    test('refuses a single over-long rule', () {
      expect(
        () => assertBoundedClashSubscription(
          clash(
            rawRules: <dynamic>[
              'MATCH,DIRECT',
              'DOMAIN,${'a' * kMaxSubscriptionLineLength},DIRECT',
            ],
          ),
        ),
        throwsBounds('16384 characters'),
      );
    });

    test('ignores a non-string rule instead of crashing on it', () {
      // Clash accepts structured rules in some forks; the cap simply does not
      // apply to them.
      expect(
        () => assertBoundedClashSubscription(<String, dynamic>{
          'rules': <dynamic>[
            <String, dynamic>{'type': 'MATCH', 'proxy': 'DIRECT'},
          ],
        }),
        returnsNormally,
      );
    });

    test('treats missing and wrongly-typed sections as empty', () {
      expect(
        () => assertBoundedClashSubscription(const <String, dynamic>{}),
        returnsNormally,
      );
      expect(
        () => assertBoundedClashSubscription(<String, dynamic>{
          'proxies': 'not a list',
          'proxy-providers': <dynamic>['not a map'],
          'proxy-groups': null,
          'rules': 42,
        }),
        returnsNormally,
      );
    });

    test('does not mutate the config it is handed', () {
      final config = clash(proxies: 2, groups: 1, rules: 1);
      final before = config.toString();
      assertBoundedClashSubscription(config);
      expect(config.toString(), before);
    });
  });

  group('asClashDict / asClashList', () {
    test('read a value the way the desktop guards do', () {
      expect(asClashDict(<String, dynamic>{'a': 1}), <String, dynamic>{'a': 1});
      expect(asClashDict(<dynamic, dynamic>{1: 'x'}), <String, dynamic>{
        '1': 'x',
      });
      expect(asClashDict(<dynamic>[1, 2]), isEmpty);
      expect(asClashDict('text'), isEmpty);
      expect(asClashDict(null), isEmpty);

      expect(asClashList(<dynamic>[1, 2]), <dynamic>[1, 2]);
      expect(asClashList(<String, dynamic>{'a': 1}), isEmpty);
      expect(asClashList(null), isEmpty);
    });
  });
}
