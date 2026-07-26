/// Redaction helpers (non-negotiable N7).
///
/// A subscription URL is itself a credential: the path and the query string
/// routinely carry the user's account token. Nothing in this app may put a raw
/// subscription URL, an `Authorization` header value or the Clash controller
/// secret into a string a human might see — a snackbar, a log line, an
/// exception message, a crash report.
///
/// Port of `redactSubscriptionUrl` and the message scrubber in
/// `src/main/config/profile.ts`.
library;

/// Substituted whenever a URL cannot be parsed well enough to redact safely.
///
/// Failing closed matters: an unparseable string is exactly the case where we
/// do not know which part is the secret.
const String kRedactedUrlPlaceholder = '[redacted subscription URL]';

/// Substituted for an `Authorization` header value.
const String kRedactedAuthorization = '[redacted authorization]';

/// Longest message [redactSecrets] will return.
const int kMaxRedactedMessageLength = 512;

/// Keeps only the parts of [url] that help a user recognise which subscription
/// failed — the scheme, the host and the port — and throws the rest away.
///
/// `https://user:pw@sub.example.net/abc123/clash?token=t#frag`
///   becomes `https://sub.example.net/***?***`.
///
/// Anything without a scheme and a host (a `file:` path, a bare string, a
/// `mailto:`) collapses to [kRedactedUrlPlaceholder] rather than being echoed.
String redactUrl(String url) {
  final Uri parsed;
  try {
    parsed = Uri.parse(url.trim());
  } on FormatException {
    return kRedactedUrlPlaceholder;
  }
  if (parsed.scheme.isEmpty || parsed.host.isEmpty) {
    return kRedactedUrlPlaceholder;
  }

  final host = parsed.host.contains(':') ? '[${parsed.host}]' : parsed.host;
  final buffer = StringBuffer()
    ..write(parsed.scheme)
    ..write('://')
    ..write(host);
  // `Uri` already drops a port that equals the scheme default, so this only
  // keeps ports the user actually typed.
  if (parsed.hasPort) {
    buffer
      ..write(':')
      ..write(parsed.port);
  }
  // A path is often the secret ("/sub/<token>"), so it is reduced to a marker
  // rather than removed — the user can still see that there was one.
  buffer.write(parsed.path.isEmpty || parsed.path == '/' ? '/' : '/***');
  if (parsed.hasQuery) buffer.write('?***');
  return buffer.toString();
}

final RegExp _urlPattern = RegExp(
  r'''[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s<>"'`]+''',
);

final RegExp _authorizationPattern = RegExp(
  r'(?:Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);

// The negative lookahead keeps this from chewing on a value an earlier rule
// already replaced ("Authorization: [redacted authorization]").
final RegExp _secretAssignmentPattern = RegExp(
  r'\b(auth[-_]?token|api[-_]?key|access[-_]?key|token|password|passwd|secret|authorization|credential)(\s*[:=]\s*)(?!\[redacted)[^\s,;&]+',
  caseSensitive: false,
);

final RegExp _whitespaceRun = RegExp(r'[\r\n\t]+');

/// Scrubs a free-form message before it reaches a user or a log.
///
/// Applied in order so that a token inside a URL is caught by the URL rule
/// first: whole URLs are replaced by [redactUrl], `Bearer`/`Basic` values by
/// [kRedactedAuthorization], and `key=value` pairs whose key names a secret
/// keep the key and lose the value. The result is collapsed to a single line
/// and capped at [kMaxRedactedMessageLength] characters so a hostile server
/// cannot flood a snackbar or a log file.
String redactSecrets(String message) {
  var text = message.replaceAll(_whitespaceRun, ' ').trim();
  if (text.isEmpty) return text;
  text = text.replaceAllMapped(
    _urlPattern,
    (match) => redactUrl(match.group(0)!),
  );
  text = text.replaceAll(_authorizationPattern, kRedactedAuthorization);
  text = text.replaceAllMapped(
    _secretAssignmentPattern,
    (match) => '${match.group(1)}${match.group(2)}[redacted]',
  );
  if (text.length > kMaxRedactedMessageLength) {
    text = text.substring(0, kMaxRedactedMessageLength);
  }
  return text;
}
