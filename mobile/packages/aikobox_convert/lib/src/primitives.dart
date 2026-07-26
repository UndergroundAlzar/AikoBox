/// Primitive coercion helpers, ported verbatim from
/// `src/main/core/singbox/convert.ts`.
///
/// These are deliberately *not* "sensible Dart". Their quirks are load-bearing
/// and are locked by the shared golden corpus:
///
/// * [toStr] refuses booleans — `tls: true` must never become the string
///   `"true"` in an emitted sing-box field.
/// * [toNum] truncates a string at the first character that is not a digit,
///   `.` or `-`, and — because JavaScript's `Number('')` is `0` — a string that
///   starts with a letter coerces to `0`, not to "no value".
/// * [compact] drops `null` and empty lists but keeps `''`, `0`, `false` and
///   empty maps.
///
/// Anything that changes an answer here changes what the core is told to do
/// with the user's traffic, so every deviation from the TypeScript is a bug.
library;

/// The untyped JSON-ish shape both the Clash input and the sing-box output use.
typedef Dict = Map<String, dynamic>;

/* ------------------------- JavaScript semantics --------------------------- */

/// JavaScript truthiness, needed because the original uses `a || b` as a
/// fallback operator in a dozen places and `''` / `0` are falsy there.
bool jsTruthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is String) return value.isNotEmpty;
  if (value is num) return value != 0 && !value.isNaN;
  return true; // objects and arrays, including empty ones
}

/// `a || b` for strings: an empty string falls through.
String? strOr(String? a, String? b) => (a != null && a.isNotEmpty) ? a : b;

/// `a || fallback` for strings.
String strOrElse(String? a, String fallback) =>
    (a != null && a.isNotEmpty) ? a : fallback;

/// `a || fallback` for numbers: `0` falls through, matching JS.
num numOrElse(num? a, num fallback) => (a != null && a != 0) ? a : fallback;

/// Collapses a double that holds an integral value back to an `int`.
///
/// JavaScript has one number type and `JSON.stringify(20.0)` emits `20`. Dart
/// would emit `20.0`, which Go rejects when unmarshalling into an `int` field,
/// so every number that leaves this library goes through here first.
num normalizeNumber(num value) {
  if (value is int) return value;
  final double d = value.toDouble();
  if (!d.isFinite) return d;
  if (d == d.truncateToDouble() && d.abs() <= 9007199254740992.0) {
    return d.toInt();
  }
  return d;
}

/// `String(value)` for a finite number.
String jsNumToString(num value) {
  final num normalized = normalizeNumber(value);
  if (normalized is int) return normalized.toString();
  return normalized.toString();
}

/// `String(value)` for the handful of shapes a Clash `rules:` entry can hold.
String jsStringify(Object? value) {
  if (value == null) return 'null';
  if (value is String) return value;
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) {
    if (value.isFinite) return jsNumToString(value);
    if (value.isNaN) return 'NaN';
    return value.isNegative ? '-Infinity' : 'Infinity';
  }
  if (value is List) return value.map(jsStringify).join(',');
  if (value is Map) return '[object Object]';
  return value.toString();
}

/// `Number(text)` restricted to the decimal forms [toNum] can produce.
double? jsNumber(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  return double.tryParse(trimmed);
}

/// `parseInt(text)` — leading whitespace, optional sign, longest digit run.
int? jsParseInt(String text) {
  final RegExpMatch? match = RegExp(r'^\s*([+-]?\d+)').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/* ---------------------------- shape coercion ------------------------------ */

/// `asDict` — anything that is not a non-array object becomes `{}`.
Dict asDict(Object? value) {
  if (value is Dict) return value;
  if (value is Map) {
    final Dict out = <String, dynamic>{};
    value.forEach((Object? key, Object? entry) {
      out[key is String ? key : jsStringify(key)] = entry;
    });
    return out;
  }
  return <String, dynamic>{};
}

/// `asArray` — anything that is not an array becomes `[]`.
List<Object?> asArray(Object? value) =>
    value is List ? value : const <Object?>[];

/// `toStr` — strings pass through, finite numbers stringify, everything else
/// (notably booleans) is refused.
String? toStr(Object? value) {
  if (value is String) return value;
  if (value is num && value.isFinite) return jsNumToString(value);
  return null;
}

/// `toNum` — see the library doc comment; the truncation is intentional.
num? toNum(Object? value) {
  if (value is num && value.isFinite) return normalizeNumber(value);
  if (value is String && value.trim().isNotEmpty) {
    final String truncated =
        value.trim().replaceFirst(RegExp(r'[^\d.-].*$'), '');
    final double? parsed = jsNumber(truncated);
    if (parsed != null && parsed.isFinite) return normalizeNumber(parsed);
  }
  return null;
}

/// `toBool` — real booleans plus the two YAML-quoted spellings.
bool? toBool(Object? value) {
  if (value is bool) return value;
  if (value == 'true') return true;
  if (value == 'false') return false;
  return null;
}

/// `toStrArray` — a bare string becomes a one-element list, `''` becomes empty.
List<String> toStrArray(Object? value) {
  if (value is String) return value.isEmpty ? <String>[] : <String>[value];
  return asArray(value)
      .map(toStr)
      .whereType<String>()
      .toList(growable: true);
}

/// `compact` — drop `null` and empty lists, keep `''`, `0`, `false` and `{}`.
Dict compact(Dict source) {
  final Dict out = <String, dynamic>{};
  source.forEach((String key, Object? value) {
    if (value == null) return;
    if (value is List && value.isEmpty) return;
    out[key] = value;
  });
  return out;
}

/// Order-preserving `[...new Set(values)]`.
List<T> dedupe<T>(Iterable<T> values) {
  final Set<T> seen = <T>{};
  final List<T> out = <T>[];
  for (final T value in values) {
    if (seen.add(value)) out.add(value);
  }
  return out;
}

/* ------------------------------- addresses -------------------------------- */

final RegExp _ipv4Literal = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _hexish = RegExp(r'^[0-9a-fA-F:.]+$');

/// True when [host] is an IP literal rather than a domain that would itself
/// need resolving.
bool isIpLiteral(String host) {
  if (_ipv4Literal.hasMatch(host)) return true;
  return host.contains(':') && _hexish.hasMatch(host);
}

/// The result of [parseHostPort].
class HostPort {
  const HostPort(this.host, this.port);

  final String host;
  final int? port;
}

final RegExp _bracketed = RegExp(r'^\[([^\]]+)\](?::(\d+))?$');

/// Parses `host:port`, `[v6]:port`, `:port` and a bare `host`.
HostPort parseHostPort(String value) {
  final String trimmed = value.trim();
  final RegExpMatch? bracket = _bracketed.firstMatch(trimmed);
  if (bracket != null) {
    final String? rawPort = bracket.group(2);
    return HostPort(
      bracket.group(1)!,
      rawPort == null ? null : jsParseInt(rawPort),
    );
  }
  // A bare IPv6 literal has more than one colon and no brackets.
  if (':'.allMatches(trimmed).length > 1) return HostPort(trimmed, null);
  final int index = trimmed.lastIndexOf(':');
  if (index == -1) return HostPort(trimmed, null);
  return HostPort(
    trimmed.substring(0, index),
    jsParseInt(trimmed.substring(index + 1)),
  );
}

/* ------------------------------- quantities ------------------------------- */

final RegExp _bandwidth = RegExp(r'^(\d+(?:\.\d+)?)\s*([KMGT]?)([bB])ps$');
const Map<String, double> _bandwidthPowers = <String, double>{
  '': 1e-6,
  'K': 1e-3,
  'M': 1,
  'G': 1e3,
  'T': 1e6,
};

/// Clash bandwidth strings (`"30 Mbps"`, `"2 GBps"`) to sing-box megabits.
///
/// A capital `B` means bytes and multiplies by 8. Anything that does not match
/// the unit grammar falls back to [toNum], keeping bare numbers usable.
num? bandwidthMbps(Object? value) {
  if (value is num && value.isFinite) return normalizeNumber(value);
  if (value is! String) return null;
  final RegExpMatch? match = _bandwidth.firstMatch(value.trim());
  if (match == null) return toNum(value);
  final double amount = double.parse(match.group(1)!);
  final double power = _bandwidthPowers[match.group(2)!]!;
  final int bytesMultiplier = match.group(3) == 'B' ? 8 : 1;
  return normalizeNumber(amount * power * bytesMultiplier);
}

final RegExp _dashRange = RegExp(r'^(\d+)\s*-\s*(\d+)$');

/// Clash port lists / ranges to sing-box `server_ports` (`"20000:30000"`).
List<String> portRanges(Object? value) {
  final List<String> out = <String>[];
  for (final String entry in toStrArray(value)) {
    for (final String part in entry.split(',')) {
      final String trimmed = part.trim();
      final String normalized = trimmed.replaceFirstMapped(
        _dashRange,
        (Match m) => '${m.group(1)}:${m.group(2)}',
      );
      if (normalized.isNotEmpty) out.add(normalized);
    }
  }
  return out;
}

/// Clash `ip-version` to sing-box `domain_strategy`.
String? mapIpVersion(Object? value) {
  switch (toStr(value)?.toLowerCase()) {
    case 'ipv4':
      return 'ipv4_only';
    case 'ipv6':
      return 'ipv6_only';
    case 'ipv4-prefer':
    case 'prefer-ipv4':
      return 'prefer_ipv4';
    case 'ipv6-prefer':
    case 'prefer-ipv6':
      return 'prefer_ipv6';
    default:
      return null;
  }
}

final RegExp _regexMeta = RegExp(r'[|\\{}()\[\]^$+?.]');

/// `*`-wildcard to an anchored regular expression.
String wildcardToRegex(String value) {
  final Iterable<String> parts = value.split('*').map(
        (String part) => part.replaceAllMapped(
          _regexMeta,
          (Match m) => '\\${m.group(0)}',
        ),
      );
  return '^${parts.join('.*')}\$';
}
