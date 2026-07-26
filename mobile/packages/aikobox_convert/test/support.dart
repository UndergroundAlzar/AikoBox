/// Shared helpers for the converter tests.
///
/// The vitest suite this port mirrors leans heavily on `toMatchObject`, which
/// asserts a *subset* of an object. [expectSubset] is the equivalent, and it
/// reports the failing path rather than dumping two large maps.
library;

import 'package:aikobox_convert/internals.dart';
import 'package:test/test.dart';

export 'package:aikobox_convert/internals.dart';

/// The default profile the desktop suite builds every case on top of.
Dict base([Dict extra = const <String, dynamic>{}]) {
  return <String, dynamic>{
    'mixed-port': 7890,
    'log-level': 'info',
    'mode': 'rule',
    'ipv6': true,
    'external-controller': '127.0.0.1:9097',
    'secret': 'test-secret',
    'proxies': <Object?>[],
    'proxy-groups': <Object?>[],
    'rules': <Object?>[],
    ...extra,
  };
}

/// The desktop suite runs without a platform, which the Dart port spells as the
/// empty string. Cases that care about a platform pass one explicitly.
const ConvertOptions kNoPlatform = ConvertOptions(platform: '');

List<Dict> outboundsOf(Dict config) =>
    (config['outbounds'] as List<Object?>? ?? const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> endpointsOf(Dict config) =>
    (config['endpoints'] as List<Object?>? ?? const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> inboundsOf(Dict config) =>
    (config['inbounds'] as List<Object?>? ?? const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> routeRules(Dict config) =>
    ((config['route'] as Dict)['rules'] as List<Object?>? ??
            const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> dnsServers(Dict config) =>
    ((config['dns'] as Dict)['servers'] as List<Object?>? ??
            const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> dnsRules(Dict config) =>
    ((config['dns'] as Dict)['rules'] as List<Object?>? ?? const <Object?>[])
        .cast<Dict>()
        .toList();

List<Dict> ruleSetsOf(Dict config) =>
    ((config['route'] as Dict)['rule_set'] as List<Object?>? ??
            const <Object?>[])
        .cast<Dict>()
        .toList();

/// The outbound with [tag]; fails the test when it is missing.
Dict outbound(Dict config, String tag) {
  final Dict? found = firstWhereOrNull(outboundsOf(config), tag);
  expect(found, isNotNull, reason: 'outbound "$tag" should exist');
  return found!;
}

/// The endpoint with [tag]; fails the test when it is missing.
Dict endpoint(Dict config, String tag) {
  final Dict? found = firstWhereOrNull(endpointsOf(config), tag);
  expect(found, isNotNull, reason: 'endpoint "$tag" should exist');
  return found!;
}

Dict? firstWhereOrNull(List<Dict> list, String tag) {
  for (final Dict item in list) {
    if (item['tag'] == tag) return item;
  }
  return null;
}

Dict? findWhere(List<Dict> list, bool Function(Dict) test) {
  for (final Dict item in list) {
    if (test(item)) return item;
  }
  return null;
}

/// `expect(actual).toMatchObject(expected)` — every key in [expected] must be
/// present in [actual] and deep-equal.
void expectSubset(
  Object? actual,
  Dict expected, {
  String path = 'root',
}) {
  expect(actual, isA<Map<String, dynamic>>(), reason: 'at $path');
  final Dict map = actual! as Dict;
  expected.forEach((String key, Object? value) {
    expect(map.containsKey(key), isTrue,
        reason: 'expected key "$key" at $path');
    if (value is Map<String, dynamic>) {
      expectSubset(map[key], value, path: '$path.$key');
    } else {
      expect(map[key], equals(value), reason: 'at $path.$key');
    }
  });
}

/// `expect(list).toContain(value)` for the string list assertions.
Matcher containsString(String needle) => contains(needle);

/// The desktop suite frequently does `warnings.join('\n')` and matches a regex.
String joined(List<String> lines) => lines.join('\n');

/// A list of string values held in a dynamic field.
List<String> strings(Object? value) =>
    (value as List<Object?>? ?? const <Object?>[]).cast<String>().toList();

/// A list of num values held in a dynamic field.
List<num> numbers(Object? value) =>
    (value as List<Object?>? ?? const <Object?>[]).cast<num>().toList();
