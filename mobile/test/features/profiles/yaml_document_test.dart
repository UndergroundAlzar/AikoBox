import 'package:aikobox_mobile/features/profiles/data/yaml_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseYamlMap', () {
    test('an empty document is an empty mapping', () {
      expect(parseYamlMap(''), isEmpty);
      expect(parseYamlMap('   \n\n'), isEmpty);
      expect(parseYamlMap('# only a comment\n'), isEmpty);
    });

    test('plain Dart collections come back, not YAML views', () {
      final parsed = parseYamlMap('''
mixed-port: 7890
proxies:
  - name: a
    type: ss
''');
      expect(parsed['mixed-port'], 7890);
      final proxies = parsed['proxies'];
      expect(proxies, isA<List<dynamic>>());
      // A YamlList would refuse this; the editors and the merge both need real
      // growable collections.
      (proxies as List<dynamic>).add(<String, dynamic>{'name': 'b'});
      expect(proxies, hasLength(2));
      expect(proxies.first, isA<Map<String, dynamic>>());
    });

    test('a non-mapping document is an error', () {
      expect(
        () => parseYamlMap('- a\n- b\n'),
        throwsA(isA<YamlDocumentException>()),
      );
      expect(
        () => parseYamlMap('just a scalar'),
        throwsA(isA<YamlDocumentException>()),
      );
    });

    test('a syntax error carries a 1-based position', () {
      try {
        parseYamlMap('a: 1\nb: [unclosed\n');
        fail('expected a YamlDocumentException');
      } on YamlDocumentException catch (error) {
        expect(error.hasPosition, isTrue);
        expect(error.line, greaterThanOrEqualTo(1));
        expect(error.column, greaterThanOrEqualTo(1));
        expect(error.message, isNotEmpty);
      }
    });

    test('the reported line points at the offending line', () {
      try {
        parseYamlMap('good: 1\nalso-good: 2\nbad: [\n');
        fail('expected a YamlDocumentException');
      } on YamlDocumentException catch (error) {
        expect(error.line, greaterThanOrEqualTo(3));
      }
    });
  });

  group('validateYamlMap', () {
    test('null for a good document', () {
      expect(validateYamlMap('a: 1\n'), isNull);
      expect(validateYamlMap(''), isNull);
    });

    test('the failure for a bad one', () {
      final failure = validateYamlMap('a: [\n');
      expect(failure, isNotNull);
      expect(failure!.hasPosition, isTrue);
    });

    test('a list document is refused', () {
      expect(validateYamlMap('- a\n'), isNotNull);
    });
  });

  group('emitYaml', () {
    test('round-trips a config', () {
      final original = <String, dynamic>{
        'mixed-port': 7890,
        'allow-lan': false,
        'rules': <String>['DOMAIN,a.com,DIRECT', 'MATCH,PROXY'],
        'dns': <String, dynamic>{
          'enable': true,
          'nameserver': <String>['1.1.1.1'],
        },
      };
      expect(parseYamlMap(emitYaml(original)), original);
    });

    test('always ends with a newline', () {
      expect(emitYaml(<String, dynamic>{'a': 1}), endsWith('\n'));
    });

    test('quotes a value that would otherwise change type', () {
      final emitted = emitYaml(<String, dynamic>{'password': '1234'});
      expect(parseYamlMap(emitted)['password'], '1234');
    });
  });

  group('plainYaml', () {
    test('leaves plain values alone', () {
      expect(plainYaml(null), isNull);
      expect(plainYaml(7), 7);
      expect(plainYaml('a'), 'a');
    });

    test('converts nested maps with non-string keys', () {
      final converted = plainYaml(<dynamic, dynamic>{
        1: <dynamic, dynamic>{true: 'x'},
      });
      expect(converted, <String, dynamic>{
        '1': <String, dynamic>{'true': 'x'},
      });
    });
  });
}
