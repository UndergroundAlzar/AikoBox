/// Turning whatever a subscription server sent into a usable Clash config.
///
/// Port of `normalizeSubscriptionPayload` in
/// `src/main/config/subscriptionPayload.ts`. Three input shapes are accepted,
/// tried in this order:
///
///  1. Clash YAML that declares `proxies` and/or `proxy-providers`.
///  2. A list of share links, one per line, `#` comments allowed.
///  3. The same list wrapped in standard or URL-safe Base64.
///
/// Anything else is refused. A body that parses as YAML but declares
/// `proxies` with the wrong shape is refused too, rather than being retried as
/// a URI list — a server that sends a broken Clash config is not sending a
/// share-link list, and guessing would turn a visible error into a silent
/// empty import.
library;

import 'bounds.dart';
import 'clash_yaml.dart';
import 'coercion.dart';
import 'exceptions.dart';
import 'share_links.dart';
import 'share_url.dart';

/// Which of the three accepted shapes a body turned out to be.
enum SubscriptionFormat {
  /// Clash YAML with `proxies` and/or `proxy-providers`.
  clashYaml,

  /// A Base64-wrapped list of share links.
  base64UriList,

  /// A plain-text list of share links.
  uriList,
}

/// The outcome of [normalizeSubscription].
class NormalizedSubscription {
  const NormalizedSubscription({
    required this.config,
    required this.format,
    this.proxyCount,
  });

  /// The Clash config, guaranteed to have at least one selectable group and a
  /// terminal rule.
  final Map<String, dynamic> config;

  /// Which shape [config] was built from.
  final SubscriptionFormat format;

  /// How many share links were parsed, for the URI-list shapes only. Null for
  /// [SubscriptionFormat.clashYaml], where nodes may come from providers that
  /// have not been fetched yet.
  final int? proxyCount;
}

/// Turns a raw subscription body into a Clash config map.
///
/// Throws [SubscriptionFormatException] when the body is unusable and
/// [SubscriptionBoundsException] when it is merely too large. The distinction
/// matters to the caller: one is "this link is wrong", the other is "this link
/// is hostile or broken".
Map<String, dynamic> normalizeSubscriptionPayload(String body) =>
    normalizeSubscription(body).config;

/// [normalizeSubscriptionPayload] plus the format and node count, which the
/// UI uses to tell the user what it just imported.
NormalizedSubscription normalizeSubscription(String content) {
  final parsed = tryParseSubscriptionYaml(content);
  _assertDeclaredClashShape(parsed);
  if (_hasUsableClashContent(parsed)) {
    final config = asClashDict(parsed);
    assertBoundedClashSubscription(config);
    return NormalizedSubscription(
      config: _synthesiseGroupAndRule(config),
      format: SubscriptionFormat.clashYaml,
    );
  }
  return _normalizeUriList(content);
}

// ---------------------------------------------------------------------------
// Clash YAML
// ---------------------------------------------------------------------------

bool _hasUsableClashContent(Object? value) {
  final config = asClashDict(value);
  return asClashList(config['proxies']).isNotEmpty ||
      asClashDict(config['proxy-providers']).isNotEmpty;
}

void _assertDeclaredClashShape(Object? value) {
  final config = asClashDict(value);
  final declaresProxies = config.containsKey('proxies');
  final declaresProviders = config.containsKey('proxy-providers');
  if (!declaresProxies && !declaresProviders) return;

  // Validate every declared root field before deciding the body is usable, so
  // a config with a good `proxy-providers` and a broken `proxies` still
  // reports the broken one instead of importing half of itself.
  if (declaresProxies && config['proxies'] is! List) {
    throw const SubscriptionFormatException(
      'Clash subscription "proxies" must be a list',
    );
  }
  final providers = config['proxy-providers'];
  if (declaresProviders && providers is! Map) {
    throw const SubscriptionFormatException(
      'Clash subscription "proxy-providers" must be a map',
    );
  }
  if (!_hasUsableClashContent(config)) {
    throw const SubscriptionFormatException(
      'Subscription contains no proxy nodes or providers',
    );
  }
}

/// Gives a group-less subscription something to select and something to match.
///
/// Many providers ship only a `proxies` list. Without a group the converter
/// has no outbound to point `route.final` at, and without a rule every packet
/// falls through to direct — which is N4's silent degradation, arrived at by
/// omission rather than by a bug.
Map<String, dynamic> _synthesiseGroupAndRule(Map<String, dynamic> config) {
  final proxies = asClashList(
    config['proxies'],
  ).map(asClashDict).toList(growable: false);
  final providerNames = asClashDict(config['proxy-providers']).keys.toList();
  final groups = asClashList(config['proxy-groups']);
  final rules = asClashList(config['rules']);

  if (groups.isEmpty) {
    final names = proxies
        .map((proxy) => _nameOf(proxy))
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isNotEmpty || providerNames.isNotEmpty) {
      config['proxy-groups'] = <dynamic>[
        <String, dynamic>{
          'name': 'Proxy',
          'type': 'select',
          if (names.isNotEmpty) 'proxies': names,
          if (providerNames.isNotEmpty) 'use': providerNames,
        },
      ];
    }
  }

  final effectiveGroups = asClashList(config['proxy-groups']).map(asClashDict);
  if (rules.isEmpty && effectiveGroups.isNotEmpty) {
    final target = _nameOf(effectiveGroups.first);
    if (target.isNotEmpty) {
      config['rules'] = <dynamic>['MATCH,$target'];
    }
  }
  return config;
}

String _nameOf(Map<String, dynamic> entry) {
  final name = entry['name'];
  if (name == null || name == false || name == '' || name == 0) return '';
  return name.toString();
}

// ---------------------------------------------------------------------------
// Share-link lists
// ---------------------------------------------------------------------------

class _UriLine {
  const _UriLine(this.value, this.lineNumber);

  final String value;

  /// 1-based, and always relative to the text the user's server actually sent,
  /// so "line 12 is broken" points at something they can look at.
  final int lineNumber;
}

List<_UriLine> _proxyUriLines(String content) {
  final lines = <_UriLine>[];
  final split = content.split(RegExp(r'\r?\n'));
  for (var index = 0; index < split.length; index += 1) {
    final value = split[index].trim();
    if (value.isEmpty || value.startsWith('#')) continue;
    lines.add(_UriLine(value, index + 1));
  }
  return lines;
}

NormalizedSubscription _normalizeUriList(String content) {
  var lines = _proxyUriLines(content);
  var format = SubscriptionFormat.uriList;

  if (!lines.any((line) => shareLinkSchemePattern.hasMatch(line.value))) {
    try {
      lines = _proxyUriLines(decodeSubscriptionBase64(content));
      format = SubscriptionFormat.base64UriList;
    } on SubscriptionFormatException {
      throw const SubscriptionFormatException(
        'Subscription is neither Clash YAML nor a Base64 proxy URI list',
      );
    }
  }

  if (lines.isEmpty) {
    throw const SubscriptionFormatException(
      'Subscription contains no proxy nodes',
    );
  }
  if (lines.length > kMaxSubscriptionProxies) {
    throw const SubscriptionBoundsException(
      'Subscription exceeds $kMaxSubscriptionProxies proxy nodes',
    );
  }
  if (lines.any((line) => line.value.length > kMaxSubscriptionLineLength)) {
    throw const SubscriptionBoundsException(
      'Subscription URI exceeds $kMaxSubscriptionLineLength characters',
    );
  }
  if (!lines.every((line) => shareLinkSchemePattern.hasMatch(line.value))) {
    throw const SubscriptionFormatException(
      'Subscription is neither Clash YAML nor a Base64 proxy URI list',
    );
  }

  final proxies = <Map<String, dynamic>>[];
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    try {
      proxies.add(parseProxyUri(line.value, index));
    } on SubscriptionFormatException catch (error) {
      // One bad node fails the whole import. Importing the rest silently is
      // how a user ends up wondering why a node they paid for is missing.
      throw SubscriptionFormatException(
        'Subscription URI line ${line.lineNumber}: ${error.message}',
      );
    }
  }

  // Clash addresses nodes by name, so duplicates would make a group ambiguous.
  final usedNames = <String>{};
  for (final proxy in proxies) {
    final parsedName = _nameOf(proxy);
    final original = parsedName.isEmpty ? 'Proxy' : parsedName;
    var name = original;
    var suffix = 2;
    while (usedNames.contains(name)) {
      name = '$original ${suffix++}';
    }
    proxy['name'] = name;
    usedNames.add(name);
  }

  final names = proxies.map((proxy) => proxy['name'] as String).toList();
  return NormalizedSubscription(
    config: <String, dynamic>{
      'proxies': proxies,
      'proxy-groups': <dynamic>[
        <String, dynamic>{'name': 'Proxy', 'type': 'select', 'proxies': names},
      ],
      'rules': <dynamic>['MATCH,Proxy'],
    },
    format: format,
    proxyCount: proxies.length,
  );
}
