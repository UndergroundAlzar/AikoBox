/// Clash `proxies:` entries to sing-box outbounds and endpoints.
///
/// Fourteen protocols, plus the transport / TLS / reality / uTLS layers they
/// share. A proxy that cannot be represented is *skipped with a warning*, never
/// silently downgraded — the caller turns "all proxies skipped" into a fatal
/// error so the profile can never quietly become direct-only.
library;

import 'primitives.dart';

/// One converted proxy: an `outbounds[]` entry, an `endpoints[]` entry
/// (wireguard), or neither plus the reason.
class OutboundBuild {
  const OutboundBuild({this.outbound, this.endpoint, this.warning});

  final Dict? outbound;
  final Dict? endpoint;
  final String? warning;
}

/// Dial options every protocol shares, applied after the protocol mapping.
void applyCommonDialFields(Dict target, Dict proxy) {
  target.addAll(
    compact(<String, dynamic>{
      'bind_interface': toStr(proxy['interface-name']),
      'tcp_fast_open': toBool(proxy['tfo']),
      'tcp_multi_path': toBool(proxy['mptcp']),
      'udp_fragment': toBool(proxy['udp-fragment']),
      'domain_strategy': mapIpVersion(proxy['ip-version']),
    }),
  );
}

/// Opt-in TLS (`tls: true`), or implicit TLS because reality is configured.
Dict? buildTls(Dict p) {
  final Dict realityOpts = asDict(p['reality-opts']);
  final bool hasReality = realityOpts.isNotEmpty;
  final bool enabled = toBool(p['tls']) == true || hasReality;
  if (!enabled) return null;

  final Dict tls = compact(<String, dynamic>{
    'enabled': true,
    'server_name': strOr(toStr(p['servername']), toStr(p['sni'])),
    'insecure': toBool(p['skip-cert-verify']),
    'alpn': toStrArray(p['alpn']),
  });

  final String? fingerprint = toStr(p['client-fingerprint']);
  if (fingerprint != null && fingerprint.isNotEmpty && fingerprint != 'none') {
    tls['utls'] = <String, dynamic>{
      'enabled': true,
      'fingerprint': fingerprint,
    };
  }
  if (hasReality) {
    tls['reality'] = compact(<String, dynamic>{
      'enabled': true,
      'public_key': toStr(realityOpts['public-key']),
      'short_id': toStr(realityOpts['short-id']),
    });
  }
  return tls;
}

/// Always-on TLS (trojan / hysteria / hysteria2 / tuic / anytls / shadowtls).
///
/// Note the `sni` / `servername` precedence is the reverse of [buildTls]; that
/// asymmetry is in the original and mirrors how the two families of Clash
/// proxies are written in the wild.
Dict buildForcedTls(Dict p, [List<String>? defaultAlpn]) {
  final List<String> alpn = toStrArray(p['alpn']);
  final Dict tls = compact(<String, dynamic>{
    'enabled': true,
    'server_name': strOr(toStr(p['sni']), toStr(p['servername'])),
    'insecure': toBool(p['skip-cert-verify']),
    'alpn': alpn.isNotEmpty ? alpn : defaultAlpn,
  });
  final String? fingerprint = toStr(p['client-fingerprint']);
  if (fingerprint != null && fingerprint.isNotEmpty && fingerprint != 'none') {
    tls['utls'] = <String, dynamic>{
      'enabled': true,
      'fingerprint': fingerprint,
    };
  }
  if (toStr(p['disable-sni']) == 'true' || toBool(p['disable-sni']) == true) {
    tls['disable_sni'] = true;
  }
  return tls;
}

/// A converted stream transport, or the reason the network is unusable.
class TransportBuild {
  const TransportBuild({this.transport, this.warning});

  final Dict? transport;
  final String? warning;
}

/// Clash `network:` + its `*-opts` to a sing-box `transport` block.
TransportBuild buildTransport(Dict p) {
  final String? network = toStr(p['network']);
  if (network == null || network.isEmpty || network == 'tcp') {
    return const TransportBuild();
  }

  switch (network) {
    case 'ws':
      final Dict opts = asDict(p['ws-opts']);
      final Dict headers = asDict(opts['headers']);
      return TransportBuild(
        transport: compact(<String, dynamic>{
          'type': 'ws',
          'path': toStr(opts['path']),
          'headers': headers.isNotEmpty ? headers : null,
          'max_early_data': toNum(opts['max-early-data']),
          'early_data_header_name': toStr(opts['early-data-header-name']),
        }),
      );
    case 'grpc':
      final Dict opts = asDict(p['grpc-opts']);
      return TransportBuild(
        transport: compact(<String, dynamic>{
          'type': 'grpc',
          'service_name': toStr(opts['grpc-service-name']),
        }),
      );
    case 'h2':
      final Dict opts = asDict(p['h2-opts']);
      return TransportBuild(
        transport: compact(<String, dynamic>{
          'type': 'http',
          'host': toStrArray(opts['host']),
          'path': toStr(opts['path']),
        }),
      );
    case 'http':
      final Dict opts = asDict(p['http-opts']);
      final List<String> paths = toStrArray(opts['path']);
      final Dict headers = asDict(opts['headers']);
      return TransportBuild(
        transport: compact(<String, dynamic>{
          'type': 'http',
          'host': toStrArray(opts['host']),
          'method': toStr(opts['method']),
          'path': paths.isNotEmpty ? paths.first : null,
          'headers': headers.isNotEmpty ? headers : null,
        }),
      );
    default:
      return TransportBuild(
        warning: 'transport network "$network" is not supported',
      );
  }
}

/* ------------------------------- protocols -------------------------------- */

OutboundBuild convertShadowsocks(Dict p, String tag) {
  final Dict outbound = compact(<String, dynamic>{
    'type': 'shadowsocks',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': toNum(p['port']),
    'method': toStr(p['cipher']),
    'password': toStr(p['password']),
    'udp_over_tcp': toBool(p['udp-over-tcp']) == true ? true : null,
  });

  final String? plugin = toStr(p['plugin']);
  if (plugin != null && plugin.isNotEmpty) {
    final Dict opts = asDict(p['plugin-opts']);
    if (plugin == 'obfs') {
      final List<String> parts = <String>[
        'obfs=${strOrElse(toStr(opts['mode']), 'http')}',
      ];
      final String? host = toStr(opts['host']);
      if (host != null && host.isNotEmpty) parts.add('obfs-host=$host');
      outbound['plugin'] = 'obfs-local';
      outbound['plugin_opts'] = parts.join(';');
    } else if (plugin == 'v2ray-plugin') {
      final List<String> parts = <String>[
        'mode=${strOrElse(toStr(opts['mode']), 'websocket')}',
      ];
      if (toBool(opts['tls']) == true) parts.add('tls');
      final String? host = toStr(opts['host']);
      final String? path = toStr(opts['path']);
      if (host != null && host.isNotEmpty) parts.add('host=$host');
      if (path != null && path.isNotEmpty) parts.add('path=$path');
      if (toBool(opts['skip-cert-verify']) == true) {
        parts.add('skipVerify=true');
      }
      outbound['plugin'] = 'v2ray-plugin';
      outbound['plugin_opts'] = parts.join(';');
      if (toBool(opts['mux']) == true) {
        outbound['plugin_opts'] = '${outbound['plugin_opts']};mux=1';
      }
    } else {
      return OutboundBuild(
        warning:
            'proxy "$tag": shadowsocks plugin "$plugin" is not supported, '
            'proxy skipped',
      );
    }
  }
  return OutboundBuild(outbound: outbound);
}

OutboundBuild convertVmess(Dict p, String tag) {
  final TransportBuild transportBuild = buildTransport(p);
  if (transportBuild.warning != null) {
    return OutboundBuild(
      warning: 'proxy "$tag": ${transportBuild.warning}, proxy skipped',
    );
  }
  final String? network = toStr(p['network']);
  final Dict? tls = buildTls(p);
  // The h2 transport in Clash implies TLS even without `tls: true`.
  final Dict? forcedTls = network == 'h2' && tls == null
      ? compact(<String, dynamic>{
          'enabled': true,
          'server_name': strOr(toStr(p['servername']), toStr(p['sni'])),
        })
      : null;
  final Dict outbound = compact(<String, dynamic>{
    'type': 'vmess',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': toNum(p['port']),
    'uuid': toStr(p['uuid']),
    'security': strOrElse(toStr(p['cipher']), 'auto'),
    'alter_id': toNum(p['alterId']) ?? toNum(p['alter-id']) ?? 0,
    'packet_encoding': toStr(p['packet-encoding']),
    'tls': tls ?? forcedTls,
    'transport': transportBuild.transport,
  });
  return OutboundBuild(outbound: outbound);
}

OutboundBuild convertVless(Dict p, String tag) {
  final TransportBuild transportBuild = buildTransport(p);
  if (transportBuild.warning != null) {
    return OutboundBuild(
      warning: 'proxy "$tag": ${transportBuild.warning}, proxy skipped',
    );
  }
  final String? flow = toStr(p['flow']);
  final bool visionFlow = flow != null && flow.startsWith('xtls-rprx-vision');
  final Dict outbound = compact(<String, dynamic>{
    'type': 'vless',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': toNum(p['port']),
    'uuid': toStr(p['uuid']),
    'flow': visionFlow ? 'xtls-rprx-vision' : null,
    'tls': buildTls(p),
    'transport': transportBuild.transport,
    'packet_encoding': toStr(p['packet-encoding']),
  });
  if (flow != null && flow.isNotEmpty && !visionFlow) {
    return OutboundBuild(
      outbound: outbound,
      warning:
          'proxy "$tag": vless flow "$flow" is not supported and was '
          'dropped',
    );
  }
  return OutboundBuild(outbound: outbound);
}

OutboundBuild convertTrojan(Dict p, String tag) {
  final TransportBuild transportBuild = buildTransport(p);
  if (transportBuild.warning != null) {
    return OutboundBuild(
      warning: 'proxy "$tag": ${transportBuild.warning}, proxy skipped',
    );
  }
  final Dict outbound = compact(<String, dynamic>{
    'type': 'trojan',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': toNum(p['port']),
    'password': toStr(p['password']),
    'tls': buildForcedTls(p),
    'transport': transportBuild.transport,
  });
  return OutboundBuild(outbound: outbound);
}

OutboundBuild convertHysteria2(Dict p, String tag) {
  final List<String> serverPorts = portRanges(
    jsTruthy(p['ports']) ? p['ports'] : p['server-ports'],
  );
  final num? hopInterval = toNum(p['hop-interval']);
  final Dict outbound = compact(<String, dynamic>{
    'type': 'hysteria2',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': serverPorts.isNotEmpty ? null : toNum(p['port']),
    'server_ports': serverPorts,
    'hop_interval': hopInterval != null
        ? '${jsNumToString(hopInterval)}s'
        : toStr(p['hop-interval']),
    'password': strOr(toStr(p['password']), toStr(p['auth'])),
    'up_mbps': integerMbps(bandwidthMbps(p['up'])),
    'down_mbps': integerMbps(bandwidthMbps(p['down'])),
    'network': toStr(p['network']),
    'tls': buildForcedTls(p, <String>['h3']),
  });
  final String? obfs = toStr(p['obfs']);
  if (obfs == 'salamander') {
    outbound['obfs'] = compact(<String, dynamic>{
      'type': 'salamander',
      'password': toStr(p['obfs-password']),
    });
  } else if (obfs != null && obfs.isNotEmpty) {
    return OutboundBuild(
      warning:
          'proxy "$tag": hysteria2 obfs "$obfs" is not supported, '
          'proxy skipped',
    );
  }
  return OutboundBuild(outbound: outbound);
}

/// Rounds a bandwidth to the integer `up_mbps` / `down_mbps` expect.
///
/// sing-box declares these fields as Go `int`, so a fractional value — which
/// `up: 12.5` or `up: "12.5Mbps"` produces, and which the desktop converter
/// emits as-is — makes the core refuse the whole config with
/// `cannot unmarshal number 12.5 into Go struct field ... of type int`. A
/// bandwidth hint is not a security property, so it is rounded rather than
/// dropped.
///
/// A positive bandwidth never rounds down to `0`: in hysteria2 `0` means
/// "unmetered, use BBR", and turning a declared cap into no cap at all would be
/// a silent behaviour change rather than a rounding error.
num? integerMbps(num? value) {
  if (value == null) return null;
  if (value is int) return value;
  final int rounded = value.round();
  if (rounded == 0 && value > 0) return 1;
  return rounded;
}

final RegExp _containsLetter = RegExp('[a-z]', caseSensitive: false);
final RegExp _fractionalMantissa = RegExp(r'^(\d+\.\d+)([\s\S]*)$');

/// Rounds a leading fractional mantissa in a hysteria v1 bandwidth string.
///
/// hysteria v1 takes `up` / `down` as unit-bearing strings, and a string that
/// already carries a unit is passed to the core untouched so its own (much
/// richer) parser can handle it. That parser rejects fractions outright —
/// `"12.5 Mbps"` fails with `unsupported unit: .5 Mbps` and takes the whole
/// config with it — so only the number is normalised, and the unit the user
/// wrote is preserved.
String withIntegerMantissa(String value) {
  final RegExpMatch? match = _fractionalMantissa.firstMatch(value);
  if (match == null) return value;
  final double? parsed = double.tryParse(match.group(1)!);
  if (parsed == null) return value;
  int rounded = parsed.round();
  if (rounded == 0 && parsed > 0) rounded = 1;
  return '$rounded${match.group(2)}';
}

OutboundBuild convertHysteria(Dict p, String tag) {
  final List<String> serverPorts = portRanges(
    jsTruthy(p['ports']) ? p['ports'] : p['server-ports'],
  );

  String? formatBandwidth(Object? value) {
    if (value is String && _containsLetter.hasMatch(value)) {
      return withIntegerMantissa(value.trim());
    }
    final num? mbps = integerMbps(bandwidthMbps(value));
    return mbps == null ? null : '${jsNumToString(mbps)} Mbps';
  }

  final num? hopInterval = toNum(p['hop-interval']);
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'hysteria',
      'tag': tag,
      'server': toStr(p['server']),
      'server_port': serverPorts.isNotEmpty ? null : toNum(p['port']),
      'server_ports': serverPorts,
      'hop_interval': hopInterval != null
          ? '${jsNumToString(hopInterval)}s'
          : toStr(p['hop-interval']),
      'up': formatBandwidth(p['up']),
      'down': formatBandwidth(p['down']),
      'obfs': toStr(p['obfs']),
      'auth': toStr(p['auth']),
      'auth_str': toStr(p['auth-str']),
      'network': strOr(toStr(p['protocol']), toStr(p['network'])),
      'tls': buildForcedTls(p, <String>['h3']),
    }),
  );
}

OutboundBuild convertSsh(Dict p, String tag) {
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'ssh',
      'tag': tag,
      'server': toStr(p['server']),
      'server_port': numOrElse(toNum(p['port']), 22),
      'user': strOr(toStr(p['user']), toStr(p['username'])),
      'password': toStr(p['password']),
      'private_key': toStr(p['private-key']),
      'private_key_path': toStr(p['private-key-path']),
      'private_key_passphrase': toStr(p['private-key-passphrase']),
      'host_key': toStrArray(p['host-key']),
      'host_key_algorithms': toStrArray(p['host-key-algorithms']),
      'client_version': toStr(p['client-version']),
    }),
  );
}

OutboundBuild convertTuic(Dict p, String tag) {
  final String? token = toStr(p['token']);
  final String? uuid = toStr(p['uuid']);
  if (token != null && token.isNotEmpty && (uuid == null || uuid.isEmpty)) {
    return OutboundBuild(
      warning: 'proxy "$tag": TUIC v4 (token) is not supported, proxy skipped',
    );
  }
  final num? heartbeat = toNum(p['heartbeat-interval']);
  final Dict outbound = compact(<String, dynamic>{
    'type': 'tuic',
    'tag': tag,
    'server': toStr(p['server']),
    'server_port': toNum(p['port']),
    'uuid': uuid,
    'password': toStr(p['password']),
    'congestion_control': strOr(
      toStr(p['congestion-controller']),
      toStr(p['congestion-control']),
    ),
    'udp_relay_mode': toStr(p['udp-relay-mode']),
    'udp_over_stream': toBool(p['udp-over-stream']),
    'zero_rtt_handshake': toBool(p['reduce-rtt']),
    'heartbeat': heartbeat != null ? '${jsNumToString(heartbeat)}ms' : null,
    'tls': buildForcedTls(p, <String>['h3']),
  });
  return OutboundBuild(outbound: outbound);
}

OutboundBuild convertWireguard(Dict p, String tag) {
  final List<String> localAddresses = <String>[];
  final String? ip4 = toStr(p['ip']);
  final String? ip6 = toStr(p['ipv6']);
  if (ip4 != null && ip4.isNotEmpty) {
    localAddresses.add(ip4.contains('/') ? ip4 : '$ip4/32');
  }
  if (ip6 != null && ip6.isNotEmpty) {
    localAddresses.add(ip6.contains('/') ? ip6 : '$ip6/128');
  }
  if (localAddresses.isEmpty) {
    return OutboundBuild(
      warning: 'proxy "$tag": wireguard is missing local ip, proxy skipped',
    );
  }

  Object? reserved;
  final Object? rawReserved = p['reserved'];
  if (rawReserved is List) {
    final List<num> nums = asArray(
      rawReserved,
    ).map(toNum).whereType<num>().toList();
    if (nums.length == 3) reserved = nums;
  } else if (rawReserved is String) {
    reserved = rawReserved;
  }

  final Dict endpoint = compact(<String, dynamic>{
    'type': 'wireguard',
    'tag': tag,
    'address': localAddresses,
    'private_key': toStr(p['private-key']),
    'mtu': toNum(p['mtu']),
    'peers': <Dict>[
      compact(<String, dynamic>{
        'address': toStr(p['server']),
        'port': toNum(p['port']),
        'public_key': toStr(p['public-key']),
        'pre_shared_key': strOr(
          toStr(p['pre-shared-key']),
          toStr(p['preshared-key']),
        ),
        'allowed_ips': <String>['0.0.0.0/0', '::/0'],
        'reserved': reserved,
      }),
    ],
  });
  return OutboundBuild(endpoint: endpoint);
}

OutboundBuild convertHttp(Dict p, String tag) {
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'http',
      'tag': tag,
      'server': toStr(p['server']),
      'server_port': toNum(p['port']),
      'username': toStr(p['username']),
      'password': toStr(p['password']),
      'tls': buildTls(p),
    }),
  );
}

OutboundBuild convertSocks5(Dict p, String tag) {
  if (toBool(p['tls']) == true) {
    return OutboundBuild(
      warning: 'proxy "$tag": socks5 over TLS is not supported, proxy skipped',
    );
  }
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'socks',
      'tag': tag,
      'version': '5',
      'server': toStr(p['server']),
      'server_port': toNum(p['port']),
      'username': toStr(p['username']),
      'password': toStr(p['password']),
    }),
  );
}

OutboundBuild convertAnytls(Dict p, String tag) {
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'anytls',
      'tag': tag,
      'server': toStr(p['server']),
      'server_port': toNum(p['port']),
      'password': toStr(p['password']),
      'idle_session_check_interval': toStr(p['idle-session-check-interval']),
      'idle_session_timeout': toStr(p['idle-session-timeout']),
      'min_idle_session': toNum(p['min-idle-session']),
      'tls': buildForcedTls(p),
    }),
  );
}

OutboundBuild convertShadowTls(Dict p, String tag) {
  final num version = toNum(p['version']) ?? 1;
  if (!const <num>[1, 2, 3].contains(version)) {
    return OutboundBuild(
      warning:
          'proxy "$tag": ShadowTLS version ${jsNumToString(version)} is '
          'invalid, proxy skipped',
    );
  }
  final String? password = toStr(p['password']);
  if (version > 1 && (password == null || password.isEmpty)) {
    return OutboundBuild(
      warning:
          'proxy "$tag": ShadowTLS v${jsNumToString(version)} requires a '
          'password, proxy skipped',
    );
  }
  return OutboundBuild(
    outbound: compact(<String, dynamic>{
      'type': 'shadowtls',
      'tag': tag,
      'server': toStr(p['server']),
      'server_port': toNum(p['port']),
      'version': version,
      'password': password,
      'tls': buildForcedTls(p),
    }),
  );
}

/// Dispatches one Clash proxy to its protocol converter.
OutboundBuild convertProxy(Dict p) {
  final String? tag = toStr(p['name']);
  if (tag == null || tag.isEmpty) {
    return const OutboundBuild(warning: 'proxy without a name was skipped');
  }
  final String? type = toStr(p['type']);
  switch (type) {
    case 'ss':
      return convertShadowsocks(p, tag);
    case 'vmess':
      return convertVmess(p, tag);
    case 'vless':
      return convertVless(p, tag);
    case 'trojan':
      return convertTrojan(p, tag);
    case 'hysteria2':
      return convertHysteria2(p, tag);
    case 'hysteria':
      return convertHysteria(p, tag);
    case 'tuic':
      return convertTuic(p, tag);
    case 'wireguard':
      return convertWireguard(p, tag);
    case 'http':
      return convertHttp(p, tag);
    case 'socks5':
      return convertSocks5(p, tag);
    case 'anytls':
      return convertAnytls(p, tag);
    case 'ssh':
      return convertSsh(p, tag);
    case 'shadowtls':
      return convertShadowTls(p, tag);
    case 'direct':
      return OutboundBuild(
        outbound: <String, dynamic>{'type': 'direct', 'tag': tag},
      );
    default:
      return OutboundBuild(
        warning:
            'proxy "$tag": type "${strOrElse(type, 'unknown')}" is not '
            'supported by sing-box, skipped',
      );
  }
}
