import 'package:aikobox_mobile/features/profiles/data/deep_merge.dart';
import 'package:aikobox_mobile/features/profiles/data/rule_overlay.dart';
import 'package:aikobox_mobile/features/profiles/data/yaml_document.dart';
import 'package:flutter_test/flutter_test.dart';

const List<String> _base = <String>[
  'DOMAIN,a.com,DIRECT',
  'GEOIP,CN,DIRECT',
  'MATCH,PROXY',
];

void main() {
  group('normaliseRuleList', () {
    test('accepts both the string and the sequence form', () {
      final rules = normaliseRuleList(<Object?>[
        'DOMAIN,a.com,DIRECT',
        <Object?>['GEOIP', 'CN', 'DIRECT'],
      ]);
      expect(rules, <String>['DOMAIN,a.com,DIRECT', 'GEOIP,CN,DIRECT']);
    });

    test('a missing or malformed node is an empty list', () {
      expect(normaliseRuleList(null), isEmpty);
      expect(normaliseRuleList('rules'), isEmpty);
    });
  });

  group('applyRuleOverlay', () {
    test('prepend goes to the top in list order', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(
          prepend: <String>['DOMAIN,x.com,PROXY', 'DOMAIN,y.com,PROXY'],
        ),
      );
      expect(result, <String>[
        'DOMAIN,x.com,PROXY',
        'DOMAIN,y.com,PROXY',
        ..._base,
      ]);
    });

    test('append goes to the bottom in list order', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(append: <String>['MATCH,DIRECT']),
      );
      expect(result, <String>[..._base, 'MATCH,DIRECT']);
    });

    test('a prepend offset counts from the top', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(prepend: <String>['2,DOMAIN,x.com,PROXY']),
      );
      expect(result, <String>[
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'DOMAIN,x.com,PROXY',
        'MATCH,PROXY',
      ]);
    });

    test('an append offset counts back from the bottom', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(append: <String>['1,DOMAIN,x.com,PROXY']),
      );
      expect(result, <String>[
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'DOMAIN,x.com,PROXY',
        'MATCH,PROXY',
      ]);
    });

    test('an offset past the end clamps instead of throwing', () {
      expect(
        applyRuleOverlay(
          _base,
          const RuleOverlay(prepend: <String>['99,DOMAIN,x.com,PROXY']),
        ).last,
        'DOMAIN,x.com,PROXY',
      );
      expect(
        applyRuleOverlay(
          _base,
          const RuleOverlay(append: <String>['99,DOMAIN,x.com,PROXY']),
        ).first,
        'DOMAIN,x.com,PROXY',
      );
    });

    test('delete matches the whole rule string verbatim', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(delete: <String>['GEOIP,CN,DIRECT']),
      );
      expect(result, <String>['DOMAIN,a.com,DIRECT', 'MATCH,PROXY']);
    });

    test('a delete that matches nothing changes nothing', () {
      expect(
        applyRuleOverlay(
          _base,
          const RuleOverlay(delete: <String>['GEOIP,CN,PROXY']),
        ),
        _base,
      );
    });

    test('delete runs last, so a rule can be prepended and then deleted', () {
      final result = applyRuleOverlay(
        _base,
        const RuleOverlay(
          prepend: <String>['DOMAIN,x.com,PROXY'],
          delete: <String>['DOMAIN,x.com,PROXY'],
        ),
      );
      expect(result, _base);
    });

    test('the base list is not modified', () {
      final base = List<String>.of(_base);
      applyRuleOverlay(base, const RuleOverlay(append: <String>['MATCH,X']));
      expect(base, _base);
    });
  });

  group('deepMerge', () {
    test('merges nested maps key by key', () {
      final result = deepMerge(
        <String, dynamic>{
          'dns': <String, dynamic>{'enable': false, 'listen': ':53'},
        },
        <String, dynamic>{
          'dns': <String, dynamic>{'enable': true},
        },
      );
      expect(result['dns'], <String, dynamic>{'enable': true, 'listen': ':53'});
    });

    test('a trailing ! replaces a block outright', () {
      final result = deepMerge(
        <String, dynamic>{
          'dns': <String, dynamic>{'enable': false, 'listen': ':53'},
        },
        <String, dynamic>{
          'dns!': <String, dynamic>{'enable': true},
        },
      );
      expect(result['dns'], <String, dynamic>{'enable': true});
    });

    test('a plain list assignment replaces', () {
      final result = deepMerge(
        <String, dynamic>{
          'rules': <String>['a'],
        },
        <String, dynamic>{
          'rules': <String>['b'],
        },
        isOverride: true,
      );
      expect(result['rules'], <String>['b']);
    });

    test('+key prepends and key+ appends, but only for an override', () {
      final prepended = deepMerge(
        <String, dynamic>{
          'rules': <String>['a'],
        },
        <String, dynamic>{
          '+rules': <String>['b'],
        },
        isOverride: true,
      );
      expect(prepended['rules'], <String>['b', 'a']);

      final appended = deepMerge(
        <String, dynamic>{
          'rules': <String>['a'],
        },
        <String, dynamic>{
          'rules+': <String>['b'],
        },
        isOverride: true,
      );
      expect(appended['rules'], <String>['a', 'b']);

      final plain = deepMerge(
        <String, dynamic>{
          'rules': <String>['a'],
        },
        <String, dynamic>{
          '+rules': <String>['b'],
        },
      );
      expect(plain['+rules'], <String>['b']);
      expect(plain['rules'], <String>['a']);
    });

    test('angle brackets escape a key that really ends in + or !', () {
      final result = deepMerge(
        <String, dynamic>{},
        <String, dynamic>{
          '<rules+>': <String>['a'],
        },
        isOverride: true,
      );
      expect(result['rules+'], <String>['a']);
    });

    test('neither argument is mutated', () {
      final target = <String, dynamic>{
        'dns': <String, dynamic>{'enable': false},
      };
      final patch = <String, dynamic>{
        'dns': <String, dynamic>{'enable': true},
      };
      deepMerge(target, patch);
      expect((target['dns'] as Map)['enable'], isFalse);
      expect((patch['dns'] as Map)['enable'], isTrue);
    });
  });

  group('ProfileOverlay', () {
    test('round-trips through YAML', () {
      const overlay = ProfileOverlay(
        rules: RuleOverlay(
          prepend: <String>['DOMAIN,a.com,DIRECT'],
          append: <String>['MATCH,PROXY'],
          delete: <String>['GEOIP,CN,DIRECT'],
        ),
        patch: <String, dynamic>{'mixed-port': 7891},
        schedule: ProfileSchedule(cron: '0 * * * *', fixedInterval: true),
      );
      final restored = ProfileOverlay.fromYaml(
        parseYamlMap(emitYaml(overlay.toYaml())),
      );
      expect(restored, overlay);
    });

    test('an empty document is the empty overlay', () {
      expect(ProfileOverlay.fromYaml(parseYamlMap('')), ProfileOverlay.empty);
      expect(ProfileOverlay.empty.isEmpty, isTrue);
    });

    test('a schedule alone does not change the config', () {
      const overlay = ProfileOverlay(
        schedule: ProfileSchedule(fixedInterval: true),
      );
      expect(overlay.isEmpty, isFalse);
      expect(overlay.changesConfig, isFalse);
    });

    test('a malformed section is treated as absent', () {
      final overlay = ProfileOverlay.fromYaml(<String, dynamic>{
        'rules': 'not a map',
        'patch': <String>['not a map either'],
      });
      expect(overlay.rules, RuleOverlay.empty);
      expect(overlay.patch, isEmpty);
    });

    test('blank rule entries are dropped', () {
      final overlay = RuleOverlay.fromYaml(<String, dynamic>{
        'prepend': <Object?>['DOMAIN,a.com,DIRECT', '', '   ', null],
      });
      expect(overlay.prepend, <String>['DOMAIN,a.com,DIRECT']);
    });
  });

  group('applyProfileOverlay', () {
    test('applies the rules and then the patch', () {
      final base = <String, dynamic>{
        'mixed-port': 7890,
        'rules': <String>['GEOIP,CN,DIRECT', 'MATCH,PROXY'],
        'dns': <String, dynamic>{'enable': false, 'listen': ':53'},
      };
      final result = applyProfileOverlay(
        base,
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,a.com,DIRECT']),
          patch: <String, dynamic>{
            'mixed-port': 7891,
            'dns': <String, dynamic>{'enable': true},
          },
        ),
      );

      expect(result['mixed-port'], 7891);
      expect(result['rules'], <String>[
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'MATCH,PROXY',
      ]);
      expect(result['dns'], <String, dynamic>{'enable': true, 'listen': ':53'});
      // The source document is untouched, which is what lets the base snapshot
      // be re-used for the next materialisation.
      expect(base['mixed-port'], 7890);
      expect((base['rules'] as List).length, 2);
    });

    test('an empty overlay is the identity', () {
      final base = <String, dynamic>{
        'rules': <String>['MATCH,PROXY'],
      };
      expect(applyProfileOverlay(base, ProfileOverlay.empty), base);
    });

    test('a patch can add rules with the +rules form', () {
      final result = applyProfileOverlay(
        <String, dynamic>{
          'rules': <String>['MATCH,PROXY'],
        },
        const ProfileOverlay(
          patch: <String, dynamic>{
            '+rules': <String>['DOMAIN,a.com,DIRECT'],
          },
        ),
      );
      expect(result['rules'], <String>[
        'DOMAIN,a.com,DIRECT',
        'MATCH,PROXY',
      ]);
    });
  });
}
