/// Deep-link parsing for `clash://`, `mihomo://` and `aikobox://`.
///
/// This is the Dart port of `src/main/deeplink.ts` up to — but not including —
/// the confirmation dialog. It is deliberately free of Flutter, Riverpod and
/// every AikoBox layer so it can be unit-tested on its own and so it is
/// obvious, by inspection, that it cannot perform I/O.
///
/// The rules it enforces come straight from the desktop implementation and its
/// test suite:
///
/// * only the three registered schemes, only the `install-config` host;
/// * the target must be a public HTTPS URL — no plaintext, no credentials in
///   the authority, no loopback, no link-local, no RFC1918/ULA address;
/// * a supplied profile name is trimmed to 120 characters;
/// * **nothing in the result that a caller is meant to display contains the
///   link.** [DeepLinkSubscription.host] is the only display-safe field. A
///   subscription token normally rides in the query string of the target URL,
///   and error dialogs end up in logs and screenshots (N7).
library;

/// The URL schemes AikoBox registers for subscription hand-off.
const Set<String> kAikoDeepLinkSchemes = <String>{'clash', 'mihomo', 'aikobox'};

/// The only deep-link host AikoBox acts on.
const String kAikoInstallConfigHost = 'install-config';

/// Profile names arriving over a deep link are cut to this many UTF-16 units,
/// matching the desktop's `profileName?.slice(0, 120)`.
const int kAikoDeepLinkNameLimit = 120;

/// Why a link that *was* addressed to AikoBox could not be acted on.
enum DeepLinkRejection {
  /// The link, or the URL inside it, does not parse.
  malformed,

  /// `install-config` without a `url` query parameter.
  missingUrl,

  /// The target is not a public HTTPS endpoint.
  insecureTarget,
}

/// The outcome of inspecting one incoming link.
sealed class DeepLinkResult {
  const DeepLinkResult();
}

/// Not ours, or a host we do not act on. The desktop no-ops here, silently,
/// and so do we — another app's link is not an error condition.
final class DeepLinkIgnored extends DeepLinkResult {
  const DeepLinkIgnored();

  @override
  String toString() => 'DeepLinkIgnored()';
}

/// Ours, but refused. [reason] is safe to map onto a message; the link is not
/// carried along, so it cannot be leaked by accident.
final class DeepLinkRejected extends DeepLinkResult {
  const DeepLinkRejected(this.reason);

  final DeepLinkRejection reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeepLinkRejected && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'DeepLinkRejected(${reason.name})';
}

/// A subscription the user may be asked about.
///
/// Nothing here is imported until the user confirms.
final class DeepLinkSubscription extends DeepLinkResult {
  const DeepLinkSubscription({
    required this.url,
    required this.host,
    this.name,
  });

  /// The subscription endpoint. Hand it to the profile store; never render it.
  final Uri url;

  /// The target's hostname, lowercased. The only part of the link that may be
  /// shown to the user.
  final String host;

  /// The `name` query parameter, trimmed and truncated. Null when absent.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeepLinkSubscription &&
          other.url == url &&
          other.host == host &&
          other.name == name;

  @override
  int get hashCode => Object.hash(url, host, name);

  /// Deliberately omits [url]: this type ends up in `debugPrint` and crash
  /// reports, and the URL is the secret.
  @override
  String toString() => 'DeepLinkSubscription(host: $host)';
}

/// Parses a raw link string.
///
/// Prefer this over [parseAikoDeepLink] at the platform boundary: a link like
/// `clash://[not-a-host` makes `Uri.parse` throw, and telling ours from
/// somebody else's has to happen before parsing can be attempted.
DeepLinkResult parseAikoDeepLinkString(String raw) {
  final String trimmed = raw.trim();
  final String lower = trimmed.toLowerCase();
  final bool addressedToUs = kAikoDeepLinkSchemes.any(
    (String scheme) => lower.startsWith('$scheme://'),
  );
  if (!addressedToUs) return const DeepLinkIgnored();

  final Uri? link = Uri.tryParse(trimmed);
  if (link == null) return const DeepLinkRejected(DeepLinkRejection.malformed);
  return parseAikoDeepLink(link);
}

/// Parses an already-decoded link.
DeepLinkResult parseAikoDeepLink(Uri link) {
  if (!kAikoDeepLinkSchemes.contains(link.scheme.toLowerCase())) {
    return const DeepLinkIgnored();
  }
  if (link.host.toLowerCase() != kAikoInstallConfigHost) {
    return const DeepLinkIgnored();
  }

  final String? rawTarget = link.queryParameters['url']?.trim();
  if (rawTarget == null || rawTarget.isEmpty) {
    return const DeepLinkRejected(DeepLinkRejection.missingUrl);
  }

  final Uri? target = Uri.tryParse(rawTarget);
  if (target == null || !target.hasScheme || !target.hasAuthority) {
    return const DeepLinkRejected(DeepLinkRejection.malformed);
  }
  if (!isPublicHttpsSubscriptionTarget(target)) {
    return const DeepLinkRejected(DeepLinkRejection.insecureTarget);
  }

  return DeepLinkSubscription(
    url: target,
    host: target.host.toLowerCase(),
    name: truncateDeepLinkName(link.queryParameters['name']),
  );
}

/// `true` when [url] is an HTTPS endpoint that could plausibly belong to a
/// third-party provider rather than to something on this device or LAN.
///
/// A deep link is attacker-reachable: any web page or any installed app can
/// fire one. Allowing `http://` would let it downgrade the fetch, and allowing
/// a private address would turn AikoBox into an SSRF probe for the local
/// network. Both are refused before the user is even asked.
bool isPublicHttpsSubscriptionTarget(Uri url) {
  if (url.scheme.toLowerCase() != 'https') return false;
  // https://user:pass@host/... — credentials in the authority are never a
  // legitimate subscription and would be echoed by any URL rendering.
  if (url.userInfo.isNotEmpty) return false;

  final String host = url.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return false;
  if (_loopbackIpv6.contains(host)) return false;
  if (_privateIpv4.hasMatch(host)) return false;
  if (_privateIpv6.hasMatch(host)) return false;
  return true;
}

/// Trims and truncates a deep-link supplied profile name.
///
/// Returns null for absent, blank, or whitespace-only names so the profile
/// store falls back to its own naming.
String? truncateDeepLinkName(String? raw) {
  if (raw == null) return null;
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= kAikoDeepLinkNameLimit) return trimmed;

  String cut = trimmed.substring(0, kAikoDeepLinkNameLimit);
  // Cutting at a fixed code-unit count can split a surrogate pair — an emoji
  // in a provider name is common enough — which renders as a replacement box.
  final int last = cut.codeUnitAt(cut.length - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut;
}

/// `Uri.host` strips the brackets from an IPv6 literal, so these are compared
/// bare.
const Set<String> _loopbackIpv6 = <String>{'::1', '0:0:0:0:0:0:0:1', '::'};

/// 0.0.0.0/8, 127/8, 10/8, 192.168/16, 169.254/16 and 172.16/12 — the same set
/// the desktop deep-link guard refuses.
final RegExp _privateIpv4 = RegExp(
  r'^(?:0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.)',
);

/// fc00::/7 (unique local) and fe80::/10 (link local).
final RegExp _privateIpv6 = RegExp(
  r'^(?:f[cd][0-9a-f]{0,2}|fe[89ab][0-9a-f]?):',
  caseSensitive: false,
);
