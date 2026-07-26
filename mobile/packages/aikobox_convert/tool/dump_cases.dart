// Emits the converter's output for a list of cases, one JSON file per case.
//
// This is the Dart half of the cross-implementation parity check described in
// ARCHITECTURE-BRIEF §5.2: the same cases are fed to `convert.ts` and to this
// package, and the two output trees must be byte-identical. It is also how a
// `spec/convert/cases/**` corpus is regenerated after an intentional change.
//
//     dart run tool/dump_cases.dart <cases.json> <out-dir>
//
// The cases file is a JSON array of objects:
//
//     {
//       "id": "airport-inline-mainstream",
//       "clashYamlFile": "relative/or/absolute/path.yaml",   // or:
//       "clash":   { ... },                                  // inline map
//       "options": { "platform": "win32", "controllerSecret": "fixed" }
//     }
//
// Each case produces `<out-dir>/<id>.json` holding `{config, warnings, errors,
// controller}` with two-space indentation and insertion-order keys.

import 'dart:convert';
import 'dart:io';

import 'package:aikobox_convert/aikobox_convert.dart';

import 'clash_yaml.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/dump_cases.dart <cases.json> <out>');
    exitCode = 64;
    return;
  }
  final File casesFile = File(args[0]);
  final Directory outDir = Directory(args[1]);
  if (!casesFile.existsSync()) {
    stderr.writeln('cases file not found: ${casesFile.path}');
    exitCode = 66;
    return;
  }
  outDir.createSync(recursive: true);

  final List<Object?> cases =
      jsonDecode(casesFile.readAsStringSync()) as List<Object?>;
  final JsonEncoder encoder = const JsonEncoder.withIndent('  ');

  for (final Object? raw in cases) {
    final Map<String, dynamic> entry = (raw as Map).cast<String, dynamic>();
    final String id = entry['id'] as String;
    final Map<String, dynamic> clash = _loadClash(entry, casesFile);
    final ConvertResult result = convertClashToSingbox(
      clash,
      options: _loadOptions(entry['options']),
    );
    File('${outDir.path}${Platform.pathSeparator}$id.json').writeAsStringSync(
      '${encoder.convert(<String, dynamic>{'config': result.config, 'warnings': result.warnings, 'errors': result.errors, 'controller': result.controller.toJson()})}\n',
    );
    stdout.writeln(
      '$id: ${result.warnings.length} warning(s), '
      '${result.errors.length} error(s)',
    );
  }
}

Map<String, dynamic> _loadClash(Map<String, dynamic> entry, File casesFile) {
  final Object? inline = entry['clash'];
  if (inline is Map) return inline.cast<String, dynamic>();
  final String path = entry['clashYamlFile'] as String;
  final File file = File(path).isAbsolute
      ? File(path)
      : File('${casesFile.parent.path}${Platform.pathSeparator}$path');
  return parseClashYamlLikeDesktop(file.readAsStringSync());
}

ConvertOptions _loadOptions(Object? raw) {
  if (raw is! Map) return const ConvertOptions(platform: '');
  final Map<String, dynamic> map = raw.cast<String, dynamic>();
  return ConvertOptions(
    platform: (map['platform'] as String?) ?? '',
    controllerSecret: map['controllerSecret'] as String?,
    autoRedirect: (map['autoRedirect'] as bool?) ?? false,
  );
}
