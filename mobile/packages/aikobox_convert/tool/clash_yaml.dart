/// Parses Clash YAML the way the desktop app's `src/main/utils/yaml.ts` does.
///
/// Shared by `tool/dump_cases.dart` and the tests. It lives outside `lib/`
/// deliberately: the converter takes an already-parsed map, and which YAML
/// reader produced it is the caller's business. Both harnesses need the *same*
/// reader, though, or a cross-implementation diff would be comparing different
/// inputs rather than different converters.
library;

import 'package:yaml/yaml.dart';

/// The desktop pre-processor: quote bare `short-id` values before parsing.
///
/// A reality short id is hex, so `1e5` would otherwise be read as a float and
/// `0123` as an int with the leading zero lost.
final RegExp _bareShortId = RegExp(
  r'''(^|\{|,)(\s*short-id:\s*)(?!['"]|null\b|Null\b|NULL\b|~)([^"'\s,}\n]+)''',
  multiLine: true,
);

Map<String, dynamic> parseClashYamlLikeDesktop(String content) {
  final String processed = content.replaceAllMapped(
    _bareShortId,
    (Match m) => '${m.group(1)}${m.group(2)}"${m.group(3)}"',
  );
  final Object? plain = plainifyYamlNode(loadYaml(processed));
  return plain is Map ? plain.cast<String, dynamic>() : <String, dynamic>{};
}

/// Turns `YamlMap` / `YamlList` into ordinary Dart collections with string keys.
Object? plainifyYamlNode(Object? value) {
  if (value is YamlMap) {
    final Map<String, dynamic> out = <String, dynamic>{};
    value.nodes.forEach((Object? key, YamlNode node) {
      out['$key'] = plainifyYamlNode(node.value);
    });
    return out;
  }
  if (value is YamlList) {
    return value.nodes
        .map((YamlNode node) => plainifyYamlNode(node.value))
        .toList();
  }
  if (value is Map) {
    final Map<String, dynamic> out = <String, dynamic>{};
    value.forEach((Object? key, Object? entry) {
      out['$key'] = plainifyYamlNode(entry);
    });
    return out;
  }
  if (value is List) return value.map(plainifyYamlNode).toList();
  return value;
}
