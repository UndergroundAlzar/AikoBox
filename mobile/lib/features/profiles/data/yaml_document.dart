/// YAML parsing, emitting and *positional* validation for the profile editors.
///
/// `core/profile_store.dart` already has `parseClashYaml` / `encodeYaml`, but
/// two things keep this file separate rather than reusing them:
///
///  * The editors need the **line and column** of a syntax error so the gutter
///    can point at it. `parseClashYaml` throws a bare `FormatException`.
///  * `profile_store.dart` imports `package:aikobox_subscription`, so anything
///    that touches it cannot be unit-tested until that package lands. Rule and
///    overlay logic is the part of this feature most worth testing, so it is
///    deliberately kept on this side of that boundary.
library;

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// A YAML document that did not parse, with a position the editor can show.
class YamlDocumentException implements Exception {
  const YamlDocumentException(this.message, {this.line, this.column});

  /// The parser's own message. Never contains user credentials — it describes
  /// syntax, not values.
  final String message;

  /// 1-based line of the offending token, when the parser reported one.
  final int? line;

  /// 1-based column of the offending token.
  final int? column;

  bool get hasPosition => line != null;

  @override
  String toString() => hasPosition
      ? 'YamlDocumentException($line:$column): $message'
      : 'YamlDocumentException: $message';
}

/// Recursively converts `YamlMap` / `YamlList` / `YamlScalar` into plain Dart
/// collections. The converter and the emitter both need real `Map`s and
/// `List`s, not the read-only views `package:yaml` returns.
Object? plainYaml(Object? value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.nodes.entries)
        entry.key.toString(): plainYaml(entry.value.value),
    };
  }
  if (value is YamlList) {
    return <dynamic>[for (final entry in value.nodes) plainYaml(entry.value)];
  }
  if (value is YamlScalar) return plainYaml(value.value);
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): plainYaml(entry.value),
    };
  }
  if (value is List) {
    return <dynamic>[for (final entry in value) plainYaml(entry)];
  }
  return value;
}

/// Parses [text] as a YAML mapping.
///
/// An empty document is an empty mapping — a brand new profile is legitimately
/// blank. Anything that parses to a non-mapping is an error, because every
/// consumer of this (a Clash config, an overlay document) is a mapping.
Map<String, dynamic> parseYamlMap(String text) {
  final Object? decoded = _load(text);
  if (decoded == null) return <String, dynamic>{};
  if (decoded is! Map<String, dynamic>) {
    throw const YamlDocumentException('Document is not a YAML mapping');
  }
  return decoded;
}

/// Parses [text] and returns `null` on success, or the failure otherwise.
/// Used by the editors' save path so a broken document is never written.
YamlDocumentException? validateYamlMap(String text) {
  try {
    parseYamlMap(text);
    return null;
  } on YamlDocumentException catch (error) {
    return error;
  }
}

Object? _load(String text) {
  if (text.trim().isEmpty) return null;
  try {
    return plainYaml(loadYaml(text));
  } on YamlException catch (error) {
    final start = error.span?.start;
    throw YamlDocumentException(
      error.message,
      // `SourceLocation` counts from zero; editors count from one.
      line: start == null ? null : start.line + 1,
      column: start == null ? null : start.column + 1,
    );
  } on FormatException catch (error) {
    throw YamlDocumentException(error.message);
  }
}

/// Emits a plain Dart structure as YAML text, always newline-terminated.
String emitYaml(Object? value) {
  final editor = YamlEditor('');
  editor.update(const <Object?>[], plainYaml(value));
  final text = editor.toString();
  return text.endsWith('\n') ? text : '$text\n';
}
