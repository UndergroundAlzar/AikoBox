/// Share-link (`ss://`, `vmess://`, …) to Clash proxy map.
///
/// Port of the URI half of `src/main/config/subscriptionPayload.ts`. The
/// output shape is a Clash `proxies` entry, because that is what the rest of
/// the pipeline — bounds checking, group synthesis, the sing-box converter —
/// already speaks.
///
/// Key insertion order is preserved to match the original, so a round-trip
/// through YAML reads the same on both platforms.
library;

import 'dart:convert';

import 'coercion.dart';
import 'exceptions.dart';
import 'share_url.dart';

/// Schemes the converter can turn into a sing-box outbound.
///
/// Anything outside this set is refused loudly rather than dropped, so a user
/// whose subscription is full of SSR nodes is told why nothing appeared.
const Set<String> kSupportedShareLinkSchemes = <String>{
  'ss',
  'vmess',
  'vless',
  'trojan',
  'hysteria',
  'hy',
  'hysteria2',
  'hy2',
  'tuic',
  'anytls',
  'shadowtls',
  'http',
  'socks',
  'socks5',
};

/// Transports the sing-box converter understands.
const Set<String> _supportedTransports = <String>{'ws', 'grpc', 'h2', 'http'};

/// Parses a single share link into a Clash proxy map.
///
/// Returns null when [uri] is not a share link at all or carries a scheme
/// outside [kSupportedShareLinkSchemes]; throws
/// [SubscriptionFormatException] when the scheme is supported but the link is
/// malformed.
Map<String, dynamic>? parseShareLink(String uri) {
  final trimmed = uri.trim();
  final match = shareLinkSchemePattern.firstMatch(trimmed);
  if (match == null) return null;
  if (!kSupportedShareLinkSchemes.contains(match.group(1)!.toLowerCase())) {
    return null;
  }
  return parseProxyUri(trimmed, 0);
}

/// Parses one share link, using [index] only to build a fallback display name.
///
/// Unlike [parseShareLink] this refuses an unsupported scheme with a message,
/// which is what the subscription path wants: inside a list of nodes, silently
/// skipping is how a user ends up with a config that routes nowhere.
Map<String, dynamic> parseProxyUri(String uri, int index) {
  final match = shareLinkSchemePattern.firstMatch(uri);
  if (match == null) {
    throw const SubscriptionFormatException('not a proxy URI');
  }
  final scheme = match.group(1)!.toLowerCase();
  if (!kSupportedShareLinkSchemes.contains(scheme)) {
    throw SubscriptionFormatException(
      'proxy URI scheme "$scheme" is not supported by the sing-box converter',
    );
  }
  final fallback = '${scheme.toUpperCase()}-${index + 1}';
  if (scheme == 'ss') return _parseShadowsocks(uri, fallback);
  if (scheme == 'vmess') return _parseVmess(uri, fallback);
  return _parseStandardUri(uri, fallback);
}

/// Resolves the label shown in the proxy list.
///
/// Deliberately forgiving: a display name is cosmetic, so a broken escape in
/// it falls back to the raw text instead of discarding an otherwise usable
/// node. Credentials and connection fields use [strictDecodeUriComponent].
String displayName(String fragment, String fallback) {
  final raw = fragment.startsWith('#') ? fragment.substring(1) : fragment;
  String name;
  try {
    name = Uri.decodeComponent(raw);
  } catch (_) {
    name = raw;
  }
  name = name.trim();
  return name.isEmpty ? fallback : name;
}

bool? _queryBool(String? value) {
  if (value == null) return null;
  final normalized = value.toLowerCase();
  if (normalized == '1' || normalized == 'true' || normalized == 'yes') {
    return true;
  }
  if (normalized == '0' || normalized == 'false' || normalized == 'no') {
    return false;
  }
  throw SubscriptionFormatException('invalid boolean value "$value"');
}

void _applyTransport(Map<String, dynamic> proxy, ShareUrlQuery query) {
  var network = (query.get('type') ?? query.get('network') ?? '').toLowerCase();
  if (network == 'none') network = 'tcp';
  if (network.isEmpty || network == 'tcp') return;
  if (!_supportedTransports.contains(network)) {
    throw SubscriptionFormatException(
      'transport "$network" is not supported by the sing-box converter',
    );
  }
  proxy['network'] = network;
  if (network == 'ws') {
    final headers = <String, dynamic>{};
    final host = query.get('host');
    if (host != null) headers['Host'] = host;
    proxy['ws-opts'] = <String, dynamic>{
      'path': query.get('path') ?? '/',
      if (headers.isNotEmpty) 'headers': headers,
    };
  } else if (network == 'grpc') {
    proxy['grpc-opts'] = <String, dynamic>{
      'grpc-service-name':
          query.get('serviceName') ?? query.get('service-name') ?? '',
    };
  } else {
    final host = query.get('host');
    final path = query.get('path') ?? '/';
    proxy[network == 'h2' ? 'h2-opts' : 'http-opts'] = <String, dynamic>{
      'path': network == 'http' ? <dynamic>[path] : path,
      if (host != null) 'host': <dynamic>[host],
    };
  }
}

void _applyTls(
  Map<String, dynamic> proxy,
  ShareUrlQuery query, {
  bool forced = false,
}) {
  final security = (query.get('security') ?? '').toLowerCase();
  if (forced || security == 'tls' || security == 'reality') {
    proxy['tls'] = true;
  }
  final sni = query.get('sni') ?? query.get('peer');
  if (sni != null) proxy['servername'] = sni;
  final fingerprint = query.get('fp');
  if (fingerprint != null) proxy['client-fingerprint'] = fingerprint;
  final insecure = _queryBool(
    query.get('allowInsecure') ?? query.get('insecure'),
  );
  if (insecure != null) proxy['skip-cert-verify'] = insecure;
  final alpn = query.get('alpn');
  if (alpn != null) {
    proxy['alpn'] = alpn
        .split(',')
        .map(strictDecodeUriComponent)
        .where((entry) => entry.isNotEmpty)
        .toList();
  }
  if (security == 'reality') {
    proxy['reality-opts'] = <String, dynamic>{
      'public-key': query.get('pbk') ?? query.get('public-key') ?? '',
      'short-id': query.get('sid') ?? query.get('short-id') ?? '',
    };
  }
}

Map<String, dynamic> _parseStandardUri(String uri, String fallback) {
  final parsed = ShareUrl.parse(uri);
  final scheme = parsed.scheme;
  final query = parsed.query;
  // Evaluation order matters: the port is validated before the credentials are
  // decoded, and both before the host is checked, exactly as in the original.
  final proxy = <String, dynamic>{
    'name': displayName(parsed.hash, fallback),
    'type': switch (scheme) {
      'hy2' => 'hysteria2',
      'hy' => 'hysteria',
      'socks' => 'socks5',
      _ => scheme,
    },
    'server': parsed.host,
    'port': numberPort(parsed.port),
    'udp': true,
  };
  final username = strictDecodeUriComponent(parsed.rawUsername);
  final password = strictDecodeUriComponent(parsed.rawPassword);
  if (parsed.host.isEmpty) {
    throw SubscriptionFormatException('$scheme URI is missing a server');
  }

  switch (scheme) {
    case 'vless':
      if (username.isEmpty) {
        throw const SubscriptionFormatException('VLESS URI is missing a UUID');
      }
      proxy['uuid'] = username;
      final flow = query.get('flow');
      if (flow != null) proxy['flow'] = flow;
      final packetEncoding =
          query.get('packetEncoding') ?? query.get('packet-encoding');
      if (packetEncoding != null) proxy['packet-encoding'] = packetEncoding;
      _applyTransport(proxy, query);
      _applyTls(proxy, query);
      if ((query.get('security') ?? '').toLowerCase() == 'reality' &&
          query.get('pbk') == null &&
          query.get('public-key') == null) {
        throw const SubscriptionFormatException(
          'VLESS Reality URI is missing its public key',
        );
      }
    case 'trojan':
      final secret = username.isNotEmpty ? username : password;
      proxy['password'] = secret;
      if (secret.isEmpty) {
        throw const SubscriptionFormatException(
          'Trojan URI is missing a password',
        );
      }
      _applyTransport(proxy, query);
      _applyTls(proxy, query, forced: true);
    case 'hysteria2' || 'hy2':
      final secret = username.isNotEmpty
          ? username
          : password.isNotEmpty
          ? password
          : query.get('auth');
      if (secret == null || secret.isEmpty) {
        throw const SubscriptionFormatException(
          'Hysteria2 URI is missing a password',
        );
      }
      proxy['password'] = secret;
      final ports = query.get('mport') ?? query.get('ports');
      if (ports != null) proxy['ports'] = ports;
      final obfs = query.get('obfs');
      final obfsPassword = query.get('obfs-password');
      if (obfs != null) proxy['obfs'] = obfs;
      if (obfsPassword != null) proxy['obfs-password'] = obfsPassword;
      _applyTls(proxy, query, forced: true);
    case 'hysteria' || 'hy':
      proxy['auth-str'] = username.isNotEmpty
          ? username
          : password.isNotEmpty
          ? password
          : query.get('auth') ?? query.get('auth_str');
      final up = query.get('upmbps') ?? query.get('up');
      final down = query.get('downmbps') ?? query.get('down');
      final obfs = query.get('obfs');
      if (up != null) proxy['up'] = up;
      if (down != null) proxy['down'] = down;
      if (obfs != null) proxy['obfs'] = obfs;
      _applyTls(proxy, query, forced: true);
    case 'tuic':
      proxy['uuid'] = username;
      proxy['password'] = password;
      if (username.isEmpty || password.isEmpty) {
        throw const SubscriptionFormatException(
          'TUIC URI is missing a UUID or password',
        );
      }
      final congestion = query.get('congestion_control');
      if (congestion != null) proxy['congestion-controller'] = congestion;
      final udpRelay = query.get('udp_relay_mode');
      if (udpRelay != null) proxy['udp-relay-mode'] = udpRelay;
      _applyTls(proxy, query, forced: true);
    case 'anytls':
      final secret = username.isNotEmpty ? username : password;
      proxy['password'] = secret;
      if (secret.isEmpty) {
        throw const SubscriptionFormatException(
          'AnyTLS URI is missing a password',
        );
      }
      _applyTls(proxy, query, forced: true);
    case 'shadowtls':
      final secret = username.isNotEmpty ? username : password;
      proxy['password'] = secret;
      final version = jsNumber(query.get('version') ?? 3);
      if (version == null || (version != 1 && version != 2 && version != 3)) {
        throw const SubscriptionFormatException(
          'ShadowTLS URI has an invalid version',
        );
      }
      if (version > 1 && secret.isEmpty) {
        throw const SubscriptionFormatException(
          'ShadowTLS URI is missing a password',
        );
      }
      proxy['version'] = version.toInt();
      _applyTls(proxy, query, forced: true);
    case 'http' || 'socks' || 'socks5':
      if (username.isNotEmpty) proxy['username'] = username;
      if (password.isNotEmpty) proxy['password'] = password;
      if (scheme == 'http') _applyTls(proxy, query);
  }
  return proxy;
}

({String host, int port}) _splitEndpoint(String value) {
  final parsed = ShareUrl.parse('http://$value');
  // Node's `new URL` refuses an empty host for a special scheme; keeping that
  // means `ss://creds@:8388` is a refusal rather than a proxy to nowhere.
  if (parsed.host.isEmpty) {
    throw const SubscriptionFormatException('Invalid URL');
  }
  return (host: parsed.host, port: numberPort(parsed.port));
}

Map<String, dynamic> _parseShadowsocks(String uri, String fallback) {
  // Hand-rolled rather than routed through `ShareUrl`, because the SIP002 and
  // legacy forms both hide credentials in a Base64 blob that a URL parser
  // would mangle.
  final hashIndex = uri.indexOf('#');
  final fragment = hashIndex >= 0 ? uri.substring(hashIndex) : '';
  final withoutHash = hashIndex >= 0
      ? uri.substring(5, hashIndex)
      : uri.substring(5);
  final queryIndex = withoutHash.indexOf('?');
  final query = ShareUrlQuery.parse(
    queryIndex >= 0 ? withoutHash.substring(queryIndex + 1) : '',
  );
  var authority = queryIndex >= 0
      ? withoutHash.substring(0, queryIndex)
      : withoutHash;

  if (!authority.contains('@')) {
    authority = decodeSubscriptionBase64(authority);
  }
  final at = authority.lastIndexOf('@');
  if (at <= 0) {
    throw const SubscriptionFormatException('invalid Shadowsocks URI');
  }
  var credentials = authority.substring(0, at);
  final endpoint = authority.substring(at + 1);
  if (!credentials.contains(':')) {
    final percentDecoded = strictDecodeUriComponent(credentials);
    credentials = percentDecoded.contains(':')
        ? percentDecoded
        : decodeSubscriptionBase64(credentials);
  }
  final colon = credentials.indexOf(':');
  if (colon <= 0) {
    throw const SubscriptionFormatException('invalid Shadowsocks credentials');
  }
  final endpointParts = _splitEndpoint(endpoint);
  final cipher = strictDecodeUriComponent(credentials.substring(0, colon));
  final password = strictDecodeUriComponent(credentials.substring(colon + 1));
  final proxy = <String, dynamic>{
    'name': displayName(fragment, fallback),
    'type': 'ss',
    'server': endpointParts.host,
    'port': endpointParts.port,
    'cipher': cipher,
    'password': password,
    'udp': true,
  };
  if (cipher.isEmpty || password.isEmpty) {
    throw const SubscriptionFormatException('invalid Shadowsocks credentials');
  }

  final plugin = query.get('plugin');
  if (plugin != null) {
    final parts = strictDecodeUriComponent(plugin).split(';');
    final pluginName = parts.first;
    proxy['plugin'] = pluginName == 'obfs-local' ? 'obfs' : pluginName;
    final pluginOptions = <String, dynamic>{};
    for (final part in parts.skip(1)) {
      final separator = part.indexOf('=');
      final key = separator >= 0 ? part.substring(0, separator) : part;
      final value = separator >= 0 ? part.substring(separator + 1) : '';
      if (key == 'tls') {
        pluginOptions['tls'] = true;
      } else if (key.isNotEmpty) {
        pluginOptions[key == 'obfs' ? 'mode' : key] = value.isEmpty
            ? true
            : value;
      }
    }
    proxy['plugin-opts'] = pluginOptions;
  }
  return proxy;
}

Map<String, dynamic> _parseVmess(String uri, String fallback) {
  const prefix = 'vmess://';
  final encodedWithFragment = uri.substring(prefix.length);
  final hashIndex = encodedWithFragment.indexOf('#');
  final fragment = hashIndex >= 0
      ? encodedWithFragment.substring(hashIndex)
      : '';
  final encoded = hashIndex >= 0
      ? encodedWithFragment.substring(0, hashIndex)
      : encodedWithFragment;
  final decodedPayload = decodeSubscriptionBase64(encoded);

  final Object? parsedPayload;
  try {
    parsedPayload = jsonDecode(decodedPayload);
  } on FormatException {
    // The message must never echo the payload: a VMess blob is a credential.
    throw const SubscriptionFormatException('VMess URI contains invalid JSON');
  }
  final data = parsedPayload is Map
      ? parsedPayload.map((key, value) => MapEntry(key.toString(), value))
      : const <String, dynamic>{};

  final server = jsStringOrEmpty(
    jsTruthy(data['add']) ? data['add'] : data['server'],
  );
  final uuid = jsStringOrEmpty(
    jsTruthy(data['id']) ? data['id'] : data['uuid'],
  );
  if (server.isEmpty || uuid.isEmpty) {
    throw const SubscriptionFormatException(
      'VMess URI is missing server or UUID',
    );
  }

  final label = jsTruthy(data['ps'])
      ? jsToString(data['ps'])
      : jsTruthy(data['name'])
      ? jsToString(data['name'])
      : displayName(fragment, fallback);
  final alterId = jsNumber(jsTruthy(data['aid']) ? data['aid'] : 0);
  final proxy = <String, dynamic>{
    'name': label,
    'type': 'vmess',
    'server': server,
    'port': numberPort(data['port']),
    'uuid': uuid,
    'alterId': alterId == null || alterId.isNaN ? 0 : alterId.toInt(),
    'cipher': jsTruthy(data['scy']) ? jsToString(data['scy']) : 'auto',
    'udp': true,
  };

  // The JSON payload names the same knobs the URI query does, so it is
  // translated into a query and run through the shared transport/TLS code.
  final query = ShareUrlQuery.empty();
  void assign(String key, Object? value) {
    if (value == null) return;
    final text = jsToString(value);
    if (text.isEmpty) return;
    query.set(key, text);
  }

  assign('type', data['net']);
  assign('host', data['host']);
  assign('path', data['path']);
  assign('serviceName', data['path']);
  assign('security', data['tls'] == true ? 'tls' : data['tls']);
  assign('sni', data['sni']);
  assign('alpn', data['alpn']);
  assign('fp', data['fp']);
  assign('allowInsecure', data['allowInsecure']);
  _applyTransport(proxy, query);
  _applyTls(proxy, query);
  return proxy;
}
