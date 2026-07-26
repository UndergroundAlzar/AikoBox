/// Reading a subscription body as Clash YAML.
///
/// Port of `src/main/utils/yaml.ts`, which is thin but does two things that
/// matter and are easy to lose in translation:
///
///  * `short-id` values are quoted before parsing. A Reality short id such as
///    `0123` or `12e4` is a hex string, but YAML would read the first as the
///    integer 123 and the second as 120000.0, and the handshake would fail
///    with no visible cause.
///  * Merge keys (`<<: *anchor`) are resolved. Real subscriptions use anchors
///    heavily to avoid repeating node templates. `package:yaml` leaves `<<` as
///    an ordinary key, so it is resolved here.
library;

import 'package:yaml/yaml.dart';

import 'exceptions.dart';

/// Ceiling on the number of nodes materialised out of one YAML document.
///
/// Anchor expansion multiplies: a document that is small on the wire can
/// expand into an unbounded tree. This does not undo the expansion the YAML
/// parser already performed, but it stops the result from being carried any
/// further.
const int kMaxYamlNodes = 2000000;

/// Quotes bare `short-id` values so YAML does not retype them.
final RegExp _shortIdPattern = RegExp(
  r'''(^|\{|,)(\s*short-id:\s*)(?!['"]|null\b|Null\b|NULL\b|~)([^"'\s,}\n]+)''',
  multiLine: true,
);

/// Applies the `short-id` quoting fix to raw YAML text.
String quoteShortIds(String content) => content.replaceAllMapped(
  _shortIdPattern,
  (match) => '${match.group(1)}${match.group(2)}"${match.group(3)}"',
);

/// Parses [content] as YAML, returning plain Dart values, or null when it is
/// not YAML at all.
///
/// Mirrors the desktop's `try { parse(content) } catch { undefined }`: a
/// subscription body that is a Base64 blob is not a parse failure worth
/// reporting, it just means the next format should be tried.
Object? tryParseSubscriptionYaml(String content) {
  try {
    return parseSubscriptionYaml(content);
  } on SubscriptionBoundsException {
    // "Too big" is a refusal in its own right, not a hint to try the next
    // format — swallowing it would report the wrong reason to the user.
    rethrow;
  } catch (_) {
    return null;
  }
}

/// Parses [content] as YAML into plain Dart maps, lists and scalars.
///
/// Throws [SubscriptionBoundsException] if the document expands past
/// [kMaxYamlNodes], and rethrows the underlying parse error otherwise.
Object? parseSubscriptionYaml(String content) {
  final document = loadYaml(quoteShortIds(content));
  final budget = _NodeBudget(kMaxYamlNodes);
  return _plainify(document, budget);
}

class _NodeBudget {
  _NodeBudget(this.remaining);

  int remaining;

  void consume() {
    remaining -= 1;
    if (remaining < 0) {
      throw const SubscriptionBoundsException(
        'Subscription structure is too large to process',
      );
    }
  }
}

Object? _plainify(Object? node, _NodeBudget budget) {
  budget.consume();
  if (node is YamlMap) {
    final result = <String, dynamic>{};
    final merged = <Map<String, dynamic>>[];
    for (final key in node.keys) {
      final name = key is String ? key : _scalarKey(key);
      final value = node[key];
      if (name == '<<') {
        _collectMergeSources(value, merged, budget);
        continue;
      }
      result[name] = _plainify(value, budget);
    }
    // YAML merge semantics: keys written in the map win over merged ones, and
    // among several merge sources the earlier one wins.
    for (final source in merged) {
      source.forEach((key, value) => result.putIfAbsent(key, () => value));
    }
    return result;
  }
  if (node is YamlList) {
    return <dynamic>[for (final item in node) _plainify(item, budget)];
  }
  if (node is Map) {
    return <String, dynamic>{
      for (final entry in node.entries)
        _scalarKey(entry.key): _plainify(entry.value, budget),
    };
  }
  if (node is List) {
    return <dynamic>[for (final item in node) _plainify(item, budget)];
  }
  if (node is YamlScalar) return node.value;
  return node;
}

void _collectMergeSources(
  Object? value,
  List<Map<String, dynamic>> out,
  _NodeBudget budget,
) {
  if (value is YamlList || value is List) {
    for (final item in value as Iterable<dynamic>) {
      _collectMergeSources(item, out, budget);
    }
    return;
  }
  final plain = _plainify(value, budget);
  if (plain is Map<String, dynamic>) out.add(plain);
}

String _scalarKey(Object? key) {
  if (key is YamlScalar) return key.value.toString();
  return key.toString();
}
