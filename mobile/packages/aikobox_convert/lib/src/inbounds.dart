/// Clash listener ports and `tun:` to sing-box inbounds.
///
/// This is the only genuinely platform-branching part of the converter.
library;

import 'models.dart';
import 'primitives.dart';

const String kDefaultTunIpv4Address = '198.19.0.1/30';
const String kDefaultTunIpv6Address = 'fdfe:dcba:9876::1/126';

/// Resolves the tun interface addresses from the modern `address` list and the
/// legacy per-family `inet4-address` / `inet6-address` keys.
List<String> buildTunAddresses(
  Dict tun, {
  required bool ipv6Enabled,
  required List<String> warnings,
}) {
  List<String> normalize(Object? value) => toStrArray(value)
      .map((String address) => address.trim())
      .where((String address) => address.isNotEmpty)
      .toList();

  final List<String> address = normalize(tun['address']);
  final List<String> legacyIpv4 = normalize(tun['inet4-address']);
  final List<String> legacyIpv6 = normalize(tun['inet6-address']);

  // `address` is the modern combined form. When it is absent, retain mihomo's
  // legacy behaviour: the inet4/inet6 fields override their own family while
  // the other family still receives a safe default.
  final List<String> configured = address.isNotEmpty
      ? <String>[...address, ...legacyIpv4, ...legacyIpv6]
      : <String>[
          ...(legacyIpv4.isNotEmpty
              ? legacyIpv4
              : <String>[kDefaultTunIpv4Address]),
          ...(legacyIpv6.isNotEmpty
              ? legacyIpv6
              : ipv6Enabled
              ? <String>[kDefaultTunIpv6Address]
              : <String>[]),
        ];

  final List<String> ipv6Addresses = configured
      .where((String item) => item.contains(':'))
      .toList();
  List<String> enabledAddresses = ipv6Enabled
      ? configured
      : configured.where((String item) => !item.contains(':')).toList();

  if (!ipv6Enabled && ipv6Addresses.isNotEmpty) {
    warnings.add('tun IPv6 address ignored because top-level ipv6 is disabled');
  }

  // A unified address list containing only IPv6 becomes empty when IPv6 is
  // disabled. Keep the tun schema startable with the collision-resistant v4
  // default instead of falling back to the Docker/WSL-heavy 172.19.0.0/30.
  if (enabledAddresses.isEmpty) {
    enabledAddresses = <String>[kDefaultTunIpv4Address];
  }

  return dedupe(enabledAddresses);
}

/// The assembled inbound list and anything that had to be dropped.
class InboundsBuild {
  InboundsBuild();

  final List<Dict> inbounds = <Dict>[];
  final List<String> warnings = <String>[];
}

/// Builds every inbound the profile asks for that the target platform can run.
///
/// Platform matrix:
///
/// | key            | win32 | linux | darwin | android | unspecified |
/// |----------------|-------|-------|--------|---------|-------------|
/// | `redir-port`   | warn  | yes   | yes    | warn    | yes         |
/// | `tproxy-port`  | warn  | yes   | warn   | warn    | yes         |
/// | `auto-redirect`| no    | yes   | no     | gated   | no          |
///
/// Android skips redirect and tproxy outright: both need root and iptables
/// rules that a `VpnService`-hosted core cannot install, and emitting them
/// would make the core fail to start rather than fall back. `auto_redirect` is
/// gated on [ConvertOptions.autoRedirect] because it is the app, not the
/// profile, that knows whether the host has granted what it needs.
InboundsBuild buildInbounds(
  Dict clash, {
  required bool ipv6Enabled,
  required ConvertOptions options,
}) {
  final InboundsBuild build = InboundsBuild();
  final String platform = options.platform;
  final bool allowLan = toBool(clash['allow-lan']) == true;
  final String listen = allowLan
      ? (ipv6Enabled ? '::' : '0.0.0.0')
      : '127.0.0.1';

  final List<Dict> users = <Dict>[];
  for (final String entry in toStrArray(clash['authentication'])) {
    final int index = entry.indexOf(':');
    if (index == -1) continue;
    users.add(<String, dynamic>{
      'username': entry.substring(0, index),
      'password': entry.substring(index + 1),
    });
  }

  void addListener(String type, String tag, num? port) {
    if (port == null || port <= 0) return;
    build.inbounds.add(
      compact(<String, dynamic>{
        'type': type,
        'tag': tag,
        'listen': listen,
        'listen_port': port,
        'users':
            const <String>['mixed', 'socks', 'http'].contains(type) &&
                users.isNotEmpty
            ? users
            : null,
      }),
    );
  }

  addListener('mixed', 'mixed-in', toNum(clash['mixed-port']));
  addListener('socks', 'socks-in', toNum(clash['socks-port']));
  addListener('http', 'http-in', toNum(clash['port']));

  final num? redirPort = toNum(clash['redir-port']);
  if (redirPort != null && redirPort > 0) {
    if (platform == 'android') {
      build.warnings.add('redir-port is not supported on Android, skipped');
    } else if (platform == 'win32') {
      build.warnings.add('redir-port is not supported on Windows, skipped');
    } else {
      addListener('redirect', 'redir-in', redirPort);
    }
  }
  final num? tproxyPort = toNum(clash['tproxy-port']);
  if (tproxyPort != null && tproxyPort > 0) {
    if (platform == 'android') {
      build.warnings.add('tproxy-port is not supported on Android, skipped');
    } else if (platform.isNotEmpty && platform != 'linux') {
      build.warnings.add('tproxy-port is only supported on Linux, skipped');
    } else {
      addListener('tproxy', 'tproxy-in', tproxyPort);
    }
  }

  final Dict tun = asDict(clash['tun']);
  if (toBool(tun['enable']) == true) {
    final List<String> address = buildTunAddresses(
      tun,
      ipv6Enabled: ipv6Enabled,
      warnings: build.warnings,
    );
    final String? stack = toStr(tun['stack']);
    final Dict inbound = compact(<String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': toStr(tun['device']),
      'address': address,
      'mtu': numOrElse(toNum(tun['mtu']), 1500),
      'auto_route': toBool(tun['auto-route']) ?? true,
      'strict_route': toBool(tun['strict-route']) == true ? true : null,
      'stack':
          stack != null &&
              const <String>['gvisor', 'system', 'mixed'].contains(stack)
          ? stack
          : null,
      'route_address': toStrArray(tun['route-address']),
      'route_exclude_address': toStrArray(tun['route-exclude-address']),
      'endpoint_independent_nat':
          toBool(tun['endpoint-independent-nat']) == true ? true : null,
    });
    if (toBool(tun['auto-redirect']) == true) {
      if (platform == 'linux') {
        inbound['auto_redirect'] = true;
      } else if (platform == 'android') {
        if (options.autoRedirect) {
          inbound['auto_redirect'] = true;
        } else {
          build.warnings.add(
            'tun auto-redirect was requested but the app has it disabled, '
            'skipped',
          );
        }
      }
    }
    build.inbounds.add(inbound);
  }

  return build;
}

/// Reject rules that keep `allow-lan` from turning the device into an open
/// proxy for the whole subnet.
List<Dict> buildLanAccessRules(
  Dict clash,
  List<Dict> inbounds,
  List<String> warnings,
) {
  if (toBool(clash['allow-lan']) != true) return <Dict>[];

  final List<String> inboundTags = inbounds
      .where(
        (Dict inbound) => const <String>[
          'mixed',
          'http',
          'socks',
        ].contains(strOrElse(toStr(inbound['type']), '')),
      )
      .map((Dict inbound) => toStr(inbound['tag']))
      .whereType<String>()
      .where((String tag) => tag.isNotEmpty)
      .toList();
  if (inboundTags.isEmpty) return <Dict>[];

  final List<String> allowed = dedupe(
    toStrArray(clash['lan-allowed-ips']).map((String item) => item.trim()),
  ).where((String item) => item.isNotEmpty).toList();
  final List<String> denied = dedupe(
    toStrArray(clash['lan-disallowed-ips']).map((String item) => item.trim()),
  ).where((String item) => item.isNotEmpty).toList();
  final List<String> users = toStrArray(
    clash['authentication'],
  ).where((String entry) => entry.contains(':')).toList();
  if (users.isEmpty) {
    warnings.add(
      'allow-lan is enabled without authentication; LAN clients can use the '
      'proxy',
    );
  }

  final List<Dict> rules = <Dict>[];
  if (denied.isNotEmpty) {
    rules.add(<String, dynamic>{
      'inbound': inboundTags,
      'source_ip_cidr': denied,
      'action': 'reject',
    });
  }
  if (allowed.isNotEmpty) {
    final List<String> safeAllowed = dedupe(<String>[
      ...allowed,
      '127.0.0.0/8',
      '::1/128',
    ]);
    rules.add(<String, dynamic>{
      'type': 'logical',
      'mode': 'and',
      'rules': <Dict>[
        <String, dynamic>{'inbound': inboundTags},
        <String, dynamic>{'source_ip_cidr': safeAllowed, 'invert': true},
      ],
      'action': 'reject',
    });
  }
  return rules;
}
