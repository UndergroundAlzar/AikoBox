String redactSensitive(String input) {
  var output = input;
  output = output.replaceAllMapped(
    RegExp(r"""https?://[^\s<>"']+""", caseSensitive: false),
    (match) => _redactUrl(match.group(0)!),
  );
  output = output.replaceAll(
    RegExp(
      r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
      caseSensitive: false,
    ),
    '[REDACTED-ID]',
  );
  output = output.replaceAllMapped(
    RegExp(
      r'\b(token|password|passwd|secret|authorization|uuid)\s*[:=]\s*([^\s,;]+)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[REDACTED]',
  );
  return output;
}

String _redactUrl(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) {
    return '[REDACTED-URL]';
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.isEmpty ? '/' : uri.path,
  ).toString();
}
