/// Locks this port's output against the TypeScript converter it was ported
/// from.
///
/// `test/parity/expected/*.json` was produced by running `convert.ts` itself
/// (via `tool/dump_cases.dart`'s TypeScript twin) over `test/parity/cases.json`
/// and was **byte-identical** to this package's output — same values, same key
/// order, same number formatting, same warning and error strings — across all
/// nineteen cases.
///
/// Three deliberate divergences were then applied, each because the shared
/// output was something sing-box 1.13.14 refuses to load. They are the only
/// differences, they are all in this list, and each has a dedicated case in
/// `real_core_test.dart` that proves the fixed shape loads:
///
/// 1. `dns.direct-nameserver` — the desktop emits a DNS rule with an
///    `outbound: ["direct"]` matcher, deprecated in sing-box 1.12 and fatal in
///    1.13. Emitted here as `domain_resolver` on the `direct` outbound.
/// 2. `up_mbps` / `down_mbps` — Go `int` fields; a fractional Clash bandwidth
///    made the core reject the whole config. Rounded, never down to `0` from a
///    positive value.
/// 3. hysteria v1 `up` / `down` — unit-bearing strings whose fractional
///    mantissa the core's parser rejects (`unsupported unit: .5 Mbps`). Only
///    the number is rounded; the unit the user wrote survives.
///
/// A failure here means either an unintended behavioural change in this
/// package, or that the TypeScript side moved and the corpus needs
/// regenerating with `dart run tool/dump_cases.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/clash_yaml.dart';
import 'support.dart';

void main() {
  final Directory parityDir = Directory(
    <String>[
      Directory.current.path,
      'test',
      'parity',
    ].join(Platform.pathSeparator),
  );
  final File casesFile = File(
    '${parityDir.path}${Platform.pathSeparator}cases.json',
  );

  group(
    'cross-implementation parity corpus',
    () {
      final List<Object?> cases =
          jsonDecode(casesFile.readAsStringSync()) as List<Object?>;

      test('the corpus is non-trivial', () {
        expect(cases.length, greaterThanOrEqualTo(19));
      });

      for (final Object? raw in cases) {
        final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
        final String id = entry['id'] as String;

        test(id, () {
          final Object? inline = entry['clash'];
          Map<String, dynamic> clash;
          if (inline is Map) {
            clash = inline.cast<String, dynamic>();
          } else {
            final File yamlFile = File(
              '${parityDir.path}${Platform.pathSeparator}'
              '${(entry['clashYamlFile'] as String).replaceAll('/', Platform.pathSeparator)}',
            );
            if (!yamlFile.existsSync()) {
              markTestSkipped('fixture missing: ${yamlFile.path}');
              return;
            }
            clash = parseClashYamlLikeDesktop(yamlFile.readAsStringSync());
          }

          final Map<String, dynamic> options =
              ((entry['options'] as Map?) ?? const <String, dynamic>{})
                  .cast<String, dynamic>();
          final ConvertResult result = convertClashToSingbox(
            clash,
            options: ConvertOptions(
              platform: (options['platform'] as String?) ?? '',
              controllerSecret: options['controllerSecret'] as String?,
              autoRedirect: (options['autoRedirect'] as bool?) ?? false,
            ),
          );

          final File expectedFile = File(
            '${parityDir.path}${Platform.pathSeparator}expected'
            '${Platform.pathSeparator}$id.json',
          );
          expect(
            expectedFile.existsSync(),
            isTrue,
            reason: 'missing frozen output for "$id"',
          );
          final Map<String, dynamic> expectedJson =
              (jsonDecode(expectedFile.readAsStringSync()) as Map)
                  .cast<String, dynamic>();

          // Compare the encoded form so key order is part of the contract: the
          // emitted JSON is what the core parses, and a reordered `outbounds`
          // list is a different config.
          const JsonEncoder encoder = JsonEncoder.withIndent('  ');
          expect(
            encoder.convert(result.config),
            encoder.convert(expectedJson['config']),
          );
          expect(
            result.warnings,
            equals((expectedJson['warnings'] as List<Object?>).cast<String>()),
          );
          expect(
            result.errors,
            equals((expectedJson['errors'] as List<Object?>).cast<String>()),
          );
          expect(
            result.controller.toJson(),
            equals((expectedJson['controller'] as Map).cast<String, dynamic>()),
          );
        });
      }
    },
    skip: casesFile.existsSync() ? null : 'parity corpus not found',
  );
}
