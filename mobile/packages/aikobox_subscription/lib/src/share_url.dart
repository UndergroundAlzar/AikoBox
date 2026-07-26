/// A WHATWG-shaped URL parser for share links.
///
/// The desktop parser is built on Node's `new URL(...)`, and its behaviour is
/// load-bearing: which inputs throw `Invalid URL`, what `hostname` looks like
/// for a bracketed IPv6 literal, that `port` is the empty string when absent,
/// and that `searchParams` applies form decoding (`+` becomes a space).
///
/// `Uri.parse` is not a substitute. It is far more permissive — it happily
/// accepts a port of 65536 — so a straight swap would let malformed links
/// through on Android that the desktop refuses. This is a small, explicit
/// parser instead, so every divergence is visible.
///
/// Two deliberate divergences from Node, both documented at their use sites:
///
///  * Default ports are **not** stripped. Node rewrites `http://host:80` to a
///    port of `''`, which the desktop then rejects as `invalid server port` —
///    a real node on port 80 is unimportable there. Keeping the port fixes
///    that without changing any other outcome.
///  * The host is always lower-cased. Node only lower-cases hosts of special
///    schemes, so the desktop normalises the host of an `ss://` link but not
///    of a `vless://` one. DNS is case-insensitive; being consistent is
///    strictly better and never changes which links are accepted.
library;

import 'dart:convert';

import 'exceptions.dart';

/// Matches the scheme prefix the desktop uses to recognise a share link.
final RegExp shareLinkSchemePattern = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://');

final RegExp _digitsOnly = RegExp(r'^[0-9]+$');
final RegExp _forbiddenHostChars = RegExp(r'''[\\^|\[\]<>"]''');

/// The decoded query string of a share link.
///
/// [get] returns `null` for both "absent" and "present but empty", which is
/// exactly how the original treats it: every call site is either `if (value)`
/// or an `a || b || fallback` chain, and JavaScript's only falsy string is the
/// empty one.
class ShareUrlQuery {
  ShareUrlQuery._(this._entries);

  /// An empty query, ready for [set]. Used to feed the VMess JSON payload
  /// through the same transport/TLS code path as a real query string.
  ShareUrlQuery.empty() : _entries = <String, String>{};

  /// Parses `a=1&b=2`, applying `application/x-www-form-urlencoded` decoding.
  factory ShareUrlQuery.parse(String raw) {
    final entries = <String, String>{};
    if (raw.isEmpty) return ShareUrlQuery._(entries);
    for (final pair in raw.split('&')) {
      if (pair.isEmpty) continue;
      final separator = pair.indexOf('=');
      final name = separator >= 0 ? pair.substring(0, separator) : pair;
      final value = separator >= 0 ? pair.substring(separator + 1) : '';
      // First occurrence wins, matching `URLSearchParams.get`.
      entries.putIfAbsent(formUrlDecode(name), () => formUrlDecode(value));
    }
    return ShareUrlQuery._(entries);
  }

  final Map<String, String> _entries;

  /// The value for [name], or null when it is absent or empty.
  String? get(String name) {
    final value = _entries[name];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Whether [name] appears at all, empty value included.
  bool has(String name) => _entries.containsKey(name);

  /// Sets [name], replacing any previous value.
  void set(String name, String value) => _entries[name] = value;
}

/// Decodes one `application/x-www-form-urlencoded` component.
///
/// Lenient the way `URLSearchParams` is: a stray `%` or an invalid UTF-8
/// sequence is passed through or replaced rather than throwing. Fields that
/// must not be guessed at go through `strictDecodeUriComponent` instead.
String formUrlDecode(String input) {
  if (!input.contains('%') && !input.contains('+')) return input;
  final bytes = <int>[];
  final pending = StringBuffer();
  void flush() {
    if (pending.isEmpty) return;
    bytes.addAll(utf8.encode(pending.toString()));
    pending.clear();
  }

  var index = 0;
  while (index < input.length) {
    final char = input[index];
    if (char == '+') {
      flush();
      bytes.add(0x20);
      index += 1;
    } else if (char == '%' &&
        index + 2 < input.length &&
        _isHexDigit(input.codeUnitAt(index + 1)) &&
        _isHexDigit(input.codeUnitAt(index + 2))) {
      flush();
      bytes.add(int.parse(input.substring(index + 1, index + 3), radix: 16));
      index += 3;
    } else {
      pending.write(char);
      index += 1;
    }
  }
  flush();
  return utf8.decode(bytes, allowMalformed: true);
}

bool _isHexDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x46) ||
    (codeUnit >= 0x61 && codeUnit <= 0x66);

/// A parsed `scheme://user:pass@host:port/path?query#fragment` share link.
class ShareUrl {
  const ShareUrl._({
    required this.scheme,
    required this.rawUsername,
    required this.rawPassword,
    required this.host,
    required this.port,
    required this.path,
    required this.rawQuery,
    required this.hash,
    required this.query,
  });

  /// Lower-cased, without the trailing colon.
  final String scheme;

  /// Still percent-encoded. Decoding is the caller's decision, because a
  /// malformed escape in a credential must fail while one in a display name
  /// must not.
  final String rawUsername;

  /// Still percent-encoded. See [rawUsername].
  final String rawPassword;

  /// Lower-cased, brackets stripped from an IPv6 literal. Empty is legal here
  /// and is rejected later with a scheme-specific message.
  final String host;

  /// Digits, or the empty string when the link carried no port.
  final String port;

  /// Includes the leading slash; empty when the link had no path.
  final String path;

  /// Without the leading `?`.
  final String rawQuery;

  /// Includes the leading `#`, and is empty for both "no fragment" and an
  /// empty one — matching `URL.hash`.
  final String hash;

  /// The decoded [rawQuery].
  final ShareUrlQuery query;

  /// Parses [input], throwing [SubscriptionFormatException] with the message
  /// `Invalid URL` for anything Node's `new URL` would reject.
  static ShareUrl parse(String input) {
    final text = input.trim();
    final schemeMatch = shareLinkSchemePattern.firstMatch(text);
    if (schemeMatch == null) throw _invalidUrl;
    final scheme = schemeMatch.group(1)!.toLowerCase();

    var rest = text.substring(schemeMatch.end);

    // Order matters: a `#` starts the fragment even inside what looks like a
    // query, and a `?` inside a fragment is just text.
    var hash = '';
    final hashIndex = rest.indexOf('#');
    if (hashIndex >= 0) {
      final fragment = rest.substring(hashIndex + 1);
      hash = fragment.isEmpty ? '' : '#$fragment';
      rest = rest.substring(0, hashIndex);
    }

    var rawQuery = '';
    final queryIndex = rest.indexOf('?');
    if (queryIndex >= 0) {
      rawQuery = rest.substring(queryIndex + 1);
      rest = rest.substring(0, queryIndex);
    }

    var path = '';
    final pathIndex = rest.indexOf('/');
    if (pathIndex >= 0) {
      path = rest.substring(pathIndex);
      rest = rest.substring(0, pathIndex);
    }

    var authority = rest;
    var rawUsername = '';
    var rawPassword = '';
    // The last `@` wins, so a password containing `@` still parses.
    final at = authority.lastIndexOf('@');
    if (at >= 0) {
      final userinfo = authority.substring(0, at);
      authority = authority.substring(at + 1);
      final separator = userinfo.indexOf(':');
      if (separator >= 0) {
        rawUsername = userinfo.substring(0, separator);
        rawPassword = userinfo.substring(separator + 1);
      } else {
        rawUsername = userinfo;
      }
    }

    final String host;
    var port = '';
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      if (close < 0) throw _invalidUrl;
      host = authority.substring(1, close);
      final tail = authority.substring(close + 1);
      if (tail.isNotEmpty) {
        if (!tail.startsWith(':')) throw _invalidUrl;
        port = tail.substring(1);
      }
    } else {
      final separator = authority.lastIndexOf(':');
      if (separator >= 0) {
        host = authority.substring(0, separator);
        port = authority.substring(separator + 1);
      } else {
        host = authority;
      }
      if (host.contains(':')) throw _invalidUrl;
    }

    if (port.isNotEmpty) {
      if (!_digitsOnly.hasMatch(port)) throw _invalidUrl;
      final value = int.tryParse(port);
      if (value == null || value > 65535) throw _invalidUrl;
      port = value.toString();
    }

    for (final codeUnit in host.codeUnits) {
      if (codeUnit <= 0x20 || codeUnit == 0x7f) throw _invalidUrl;
    }
    if (_forbiddenHostChars.hasMatch(host)) throw _invalidUrl;

    return ShareUrl._(
      scheme: scheme,
      rawUsername: rawUsername,
      rawPassword: rawPassword,
      host: host.toLowerCase(),
      port: port,
      path: path,
      rawQuery: rawQuery,
      hash: hash,
      query: ShareUrlQuery.parse(rawQuery),
    );
  }
}

const SubscriptionFormatException _invalidUrl = SubscriptionFormatException(
  'Invalid URL',
);
