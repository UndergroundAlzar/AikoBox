/// The coercion primitives, quirks included.
///
/// These have no direct counterpart in `convert.test.ts` — the desktop suite
/// covers them only through whole-config assertions. They are pinned here
/// because ARCHITECTURE-BRIEF §5.3 calls their exact behaviour load-bearing,
/// and because "sensible Dart" would quietly change several of them.
library;

import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('toStr', () {
    test('passes strings through, including the empty string', () {
      expect(toStr('a'), 'a');
      expect(toStr(''), '');
    });

    test('stringifies finite numbers the way JavaScript does', () {
      expect(toStr(30), '30');
      expect(toStr(30.0), '30');
      expect(toStr(30.5), '30.5');
      expect(toStr(-0.0), '0');
      expect(toStr(double.infinity), isNull);
      expect(toStr(double.nan), isNull);
    });

    test('refuses booleans', () {
      // `tls: true` must never reach a sing-box string field as "true".
      expect(toStr(true), isNull);
      expect(toStr(false), isNull);
    });

    test('refuses everything else', () {
      expect(toStr(null), isNull);
      expect(toStr(<String>['a']), isNull);
      expect(toStr(<String, dynamic>{'a': 1}), isNull);
    });
  });

  group('toNum', () {
    test('passes finite numbers through', () {
      expect(toNum(443), 443);
      expect(toNum(443.5), 443.5);
      expect(toNum(double.infinity), isNull);
    });

    test('collapses integral doubles to ints so JSON stays Go-parseable', () {
      expect(toNum(443.0), isA<int>());
      expect(toNum(443.0), 443);
    });

    test('truncates a string at the first character that is not [0-9.-]', () {
      expect(toNum('443abc'), 443);
      expect(toNum('30 Mbps'), 30);
      expect(toNum(' 443 '), 443);
    });

    test('a string that starts with a non-numeric character becomes 0', () {
      // JavaScript's `Number('')` is 0, and the truncation above leaves ''.
      // Surprising, load-bearing, and the reason `port: "abc"` becomes 0 rather
      // than "absent".
      expect(toNum('abc'), 0);
      expect(toNum('Mbps'), 0);
    });

    test('rejects strings that are not a single decimal number', () {
      expect(toNum('1.2.3'), isNull);
      expect(toNum('20000-30000'), isNull);
      expect(toNum('--1'), isNull);
      expect(toNum('-'), isNull);
      expect(toNum(''), isNull);
      expect(toNum('   '), isNull);
    });

    test('refuses booleans and null', () {
      expect(toNum(true), isNull);
      expect(toNum(null), isNull);
    });
  });

  group('toBool', () {
    test('accepts booleans and the two quoted spellings only', () {
      expect(toBool(true), isTrue);
      expect(toBool(false), isFalse);
      expect(toBool('true'), isTrue);
      expect(toBool('false'), isFalse);
      expect(toBool('True'), isNull);
      expect(toBool(1), isNull);
      expect(toBool(0), isNull);
      expect(toBool(null), isNull);
    });
  });

  group('toStrArray', () {
    test('wraps a bare string, drops the empty string', () {
      expect(toStrArray('a'), <String>['a']);
      expect(toStrArray(''), isEmpty);
    });

    test('filters a list down to its stringifiable members', () {
      expect(
        toStrArray(<Object?>[
          'a',
          1,
          true,
          null,
          <String>['x'],
        ]),
        <String>['a', '1'],
      );
    });

    test('anything else is empty', () {
      expect(toStrArray(null), isEmpty);
      expect(toStrArray(<String, dynamic>{'a': 1}), isEmpty);
    });
  });

  group('compact', () {
    test('drops null and empty lists', () {
      expect(compact(<String, dynamic>{'a': null, 'b': <Object?>[]}), isEmpty);
    });

    test('keeps the empty string, zero, false and the empty map', () {
      // `password: ''` really does mean "empty password" to some protocols.
      expect(
        compact(<String, dynamic>{
          's': '',
          'n': 0,
          'b': false,
          'm': <String, dynamic>{},
        }),
        equals(<String, dynamic>{
          's': '',
          'n': 0,
          'b': false,
          'm': <String, dynamic>{},
        }),
      );
    });

    test('preserves insertion order', () {
      expect(
        compact(<String, dynamic>{'z': 1, 'a': null, 'm': 2}).keys.toList(),
        <String>['z', 'm'],
      );
    });
  });

  group('bandwidthMbps', () {
    test('understands the unit grammar', () {
      expect(bandwidthMbps('30 Mbps'), 30);
      expect(bandwidthMbps('1 Gbps'), 1000);
      expect(bandwidthMbps('2 GBps'), 16000); // capital B is bytes: x8
      expect(bandwidthMbps('100Kbps'), 0.1);
      expect(bandwidthMbps('1 Tbps'), 1000000);
      expect(bandwidthMbps('800bps'), closeTo(0.0008, 1e-12));
    });

    test('falls back to toNum for anything else', () {
      expect(bandwidthMbps(200), 200);
      expect(bandwidthMbps('200'), 200);
      expect(bandwidthMbps('200 megabits'), 200);
      expect(bandwidthMbps(null), isNull);
      expect(bandwidthMbps(true), isNull);
    });
  });

  group('integerMbps', () {
    test('rounds, because sing-box declares the field as a Go int', () {
      expect(integerMbps(12.5), 13);
      expect(integerMbps(55.4), 55);
      expect(integerMbps(30), 30);
      expect(integerMbps(null), isNull);
    });

    test('never turns a declared cap into "unmetered"', () {
      // 0 means "use BBR, no limit" in hysteria2.
      expect(integerMbps(0.0008), 1);
      expect(integerMbps(0), 0);
    });
  });

  group('withIntegerMantissa', () {
    test('rounds only the number and keeps the unit the user wrote', () {
      expect(withIntegerMantissa('12.5 Mbps'), '13 Mbps');
      // same floor as integerMbps: a stated cap never becomes "unmetered"
      expect(withIntegerMantissa('0.4Gbps'), '1Gbps');
      expect(withIntegerMantissa('1 Gbps'), '1 Gbps');
      expect(withIntegerMantissa('100 Mbps'), '100 Mbps');
      expect(withIntegerMantissa('fast'), 'fast');
    });
  });

  group('portRanges', () {
    test('normalises dashes to colons and splits on commas', () {
      expect(portRanges('20000-30000'), <String>['20000:30000']);
      expect(portRanges('20000-30000,40001'), <String>['20000:30000', '40001']);
      expect(portRanges(<String>['1-2', '3 - 4']), <String>['1:2', '3:4']);
      expect(portRanges(null), isEmpty);
      expect(portRanges(''), isEmpty);
    });
  });

  group('mapIpVersion', () {
    test('maps every Clash spelling', () {
      expect(mapIpVersion('ipv4'), 'ipv4_only');
      expect(mapIpVersion('IPv6'), 'ipv6_only');
      expect(mapIpVersion('ipv4-prefer'), 'prefer_ipv4');
      expect(mapIpVersion('prefer-ipv4'), 'prefer_ipv4');
      expect(mapIpVersion('ipv6-prefer'), 'prefer_ipv6');
      expect(mapIpVersion('prefer-ipv6'), 'prefer_ipv6');
      expect(mapIpVersion('dual'), isNull);
      expect(mapIpVersion(null), isNull);
    });
  });

  group('wildcardToRegex', () {
    test('escapes regex metacharacters but not the wildcard', () {
      expect(wildcardToRegex('*.example.com'), r'^.*\.example\.com$');
      expect(wildcardToRegex('chrome*.exe'), r'^chrome.*\.exe$');
      expect(wildcardToRegex('a+b'), r'^a\+b$');
      expect(wildcardToRegex('a(b)'), r'^a\(b\)$');
      expect(wildcardToRegex('plain'), r'^plain$');
    });

    test('the produced pattern actually matches', () {
      expect(
        RegExp(wildcardToRegex('*.example.com')).hasMatch('a.example.com'),
        isTrue,
      );
      expect(
        RegExp(wildcardToRegex('*.example.com')).hasMatch('example.comX'),
        isFalse,
      );
    });
  });

  group('parseHostPort', () {
    test('handles the four shapes', () {
      expect(parseHostPort('1.2.3.4:80').host, '1.2.3.4');
      expect(parseHostPort('1.2.3.4:80').port, 80);
      expect(parseHostPort('[::1]:9090').host, '::1');
      expect(parseHostPort('[::1]:9090').port, 9090);
      expect(parseHostPort(':9090').host, '');
      expect(parseHostPort(':9090').port, 9090);
      expect(parseHostPort('example.com').host, 'example.com');
      expect(parseHostPort('example.com').port, isNull);
    });

    test('a bare IPv6 literal keeps all of its colons', () {
      expect(
        parseHostPort('2001:4860:4860::8888').host,
        '2001:4860:4860::8888',
      );
      expect(parseHostPort('2001:4860:4860::8888').port, isNull);
    });

    test('a non-numeric port is dropped, not guessed', () {
      expect(parseHostPort('example.com:abc').port, isNull);
      expect(parseHostPort('example.com:80x').port, 80);
    });
  });

  group('isIpLiteral', () {
    test('recognises v4 and v6 literals', () {
      expect(isIpLiteral('1.2.3.4'), isTrue);
      expect(isIpLiteral('::1'), isTrue);
      expect(isIpLiteral('2001:db8::1'), isTrue);
      expect(isIpLiteral('::ffff:1.2.3.4'), isTrue);
      expect(isIpLiteral('example.com'), isFalse);
      expect(isIpLiteral('dns.google'), isFalse);
    });
  });

  group('asDict / asArray', () {
    test('coerce anything unusable to an empty container', () {
      expect(asDict(null), isEmpty);
      expect(asDict(<Object?>[1, 2]), isEmpty);
      expect(asDict('str'), isEmpty);
      expect(asArray(null), isEmpty);
      expect(asArray(<String, dynamic>{'a': 1}), isEmpty);
    });

    test('asDict stringifies non-string keys, like a JS object', () {
      expect(
        asDict(<Object?, Object?>{1: 'a', true: 'b'}),
        equals(<String, dynamic>{'1': 'a', 'true': 'b'}),
      );
    });
  });

  group('dedupe', () {
    test('keeps first occurrence order', () {
      expect(dedupe(<String>['b', 'a', 'b', 'c', 'a']), <String>[
        'b',
        'a',
        'c',
      ]);
    });
  });
}
