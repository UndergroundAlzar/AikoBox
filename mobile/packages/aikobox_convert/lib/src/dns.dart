/// Clash `dns:` / `hosts:` to the sing-box 1.12+ typed DNS server schema.
library;

import 'dart:convert';

import 'primitives.dart';

/// A Clash domain pattern list split into the four sing-box match fields.
class DomainPatterns {
  DomainPatterns();

  final List<String> domain = <String>[];
  final List<String> domainSuffix = <String>[];
  final List<String> domainKeyword = <String>[];
  final List<String> domainRegex = <String>[];

  /// Patterns that have no sing-box equivalent at all (`*`, `geosite:`,
  /// `rule-set:`). Callers report these rather than dropping them quietly.
  final List<String> skipped = <String>[];
}

/// Splits Clash domain forms into `domain` / `domain_suffix` / `domain_regex`.
DomainPatterns classifyDomainPatterns(List<String> patterns) {
  final DomainPatterns out = DomainPatterns();
  for (final String raw in patterns) {
    final String pattern = raw.trim();
    if (pattern.isEmpty) continue;
    if (pattern == '*' ||
        pattern.contains('geosite:') ||
        pattern.contains('rule-set:')) {
      out.skipped.add(pattern);
      continue;
    }
    if (pattern.startsWith('+.')) {
      out.domainSuffix.add(pattern.substring(1)); // '+.lan' -> '.lan'
      out.domain.add(pattern.substring(2)); // and the bare domain
    } else if (pattern.startsWith('*.')) {
      out.domainSuffix.add(pattern.substring(1));
    } else if (pattern.contains('*')) {
      // A wildcard inside the domain: approximate with a label-bounded regex.
      final String regex =
          '^${pattern.replaceAll('.', r'\.').replaceAll('*', '[^.]*')}\$';
      out.domainRegex.add(regex);
    } else {
      out.domain.add(pattern);
    }
  }
  return out;
}

/// The non-empty subset of [DomainPatterns] as sing-box rule fields.
Dict domainPatternFields(DomainPatterns patterns) {
  return compact(<String, dynamic>{
    'domain': patterns.domain,
    'domain_suffix': patterns.domainSuffix,
    'domain_keyword': patterns.domainKeyword,
    'domain_regex': patterns.domainRegex,
  });
}

/// One parsed nameserver: either a server object or a reason it was dropped.
class DnsServerBuild {
  const DnsServerBuild({this.server, this.warning});

  final Dict? server;
  final String? warning;
}

final RegExp _schemePrefix = RegExp(r'^([a-z0-9+]+)://', caseSensitive: false);
final RegExp _inexactHostPattern = RegExp(r'[*+]');

/// Maps one Clash nameserver URL to a sing-box (1.12+) typed DNS server.
DnsServerBuild parseNameserver(String raw, String tag) {
  String value = raw.trim();
  if (value.isEmpty) return const DnsServerBuild();

  // mihomo allows `#detour` / `#h3=true` fragments — strip them.
  final int hashIndex = value.indexOf('#');
  if (hashIndex != -1) value = value.substring(0, hashIndex);

  if (value == 'system' || value == 'system://') {
    return DnsServerBuild(
      server: <String, dynamic>{'type': 'local', 'tag': tag},
    );
  }
  if (value.startsWith('rcode://')) {
    return DnsServerBuild(
      warning: 'DNS nameserver "$raw" (rcode) is not supported, skipped',
    );
  }
  if (value.startsWith('dhcp://')) {
    final String iface = value.substring('dhcp://'.length);
    final Dict server = <String, dynamic>{'type': 'dhcp', 'tag': tag};
    if (iface.isNotEmpty && iface != 'auto' && iface != 'system') {
      server['interface'] = iface;
    }
    return DnsServerBuild(server: server);
  }

  final RegExpMatch? schemeMatch = _schemePrefix.firstMatch(value);
  final String scheme =
      schemeMatch == null ? 'udp' : schemeMatch.group(1)!.toLowerCase();
  final String rest =
      schemeMatch == null ? value : value.substring(schemeMatch.group(0)!.length);

  final int slashIndex = rest.indexOf('/');
  final String hostPort = slashIndex == -1 ? rest : rest.substring(0, slashIndex);
  final String? path = slashIndex == -1 ? null : rest.substring(slashIndex);
  final HostPort parsed = parseHostPort(hostPort);
  if (parsed.host.isEmpty) {
    return DnsServerBuild(
      warning: 'DNS nameserver "$raw" could not be parsed, skipped',
    );
  }

  switch (scheme) {
    case 'udp':
    case 'tcp':
    case 'tls':
    case 'quic':
      return DnsServerBuild(
        server: compact(<String, dynamic>{
          'type': scheme,
          'tag': tag,
          'server': parsed.host,
          'server_port': parsed.port,
        }),
      );
    case 'https':
    case 'h3':
      return DnsServerBuild(
        server: compact(<String, dynamic>{
          'type': scheme,
          'tag': tag,
          'server': parsed.host,
          'server_port': parsed.port,
          'path': path != null && path != '/dns-query' ? path : null,
        }),
      );
    default:
      return DnsServerBuild(
        warning: 'DNS nameserver "$raw" has unsupported scheme, skipped',
      );
  }
}

/// The assembled `dns` block plus the resolvers the rest of the config needs.
class DnsBuild {
  const DnsBuild({
    required this.dns,
    required this.warnings,
    required this.defaultDomainResolver,
    this.directDomainResolver,
  });

  final Dict dns;
  final List<String> warnings;

  /// `route.default_domain_resolver.server`.
  final String defaultDomainResolver;

  /// The server tag Clash's `dns.direct-nameserver` asks for, to be attached to
  /// the built-in `direct` outbound as its `domain_resolver`.
  ///
  /// The desktop converter expresses this as a DNS rule with an
  /// `outbound: ['direct']` matcher. sing-box deprecated that matcher in 1.12
  /// and **1.13 refuses to load a config containing it** unless
  /// `ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true` is set in the environment,
  /// which an Android service cannot rely on. `direct-nameserver` appears in
  /// practically every mainland Clash template, so keeping the old shape would
  /// brick most real profiles. The documented migration is an outbound-scoped
  /// `domain_resolver`, which is what this carries.
  final String? directDomainResolver;
}

/// Builds the whole `dns` section.
DnsBuild buildDns(Dict clash, {required bool ipv6Enabled}) {
  final List<String> warnings = <String>[];
  final Dict dnsConfig = asDict(clash['dns']);
  final bool dnsEnabled = toBool(dnsConfig['enable']) ?? false;
  final bool dnsIpv6Enabled = ipv6Enabled && toBool(dnsConfig['ipv6']) != false;
  final List<String> addressQueryTypes =
      dnsIpv6Enabled ? <String>['A', 'AAAA'] : <String>['A'];

  final List<Dict> servers = <Dict>[];
  final List<Dict> rules = <Dict>[];
  final Map<String, String> seen = <String, String>{}; // definition -> tag
  String bootstrapTag = 'dns-local';

  String addServer(Dict server) {
    // DNS servers are wired up before the route-level default resolver exists,
    // so a server addressed by domain has to carry its own `domain_resolver`
    // (bootstrapped off the system resolver) or the core cannot reach it.
    final String? host = toStr(server['server']);
    if (host != null && !isIpLiteral(host) && server['domain_resolver'] == null) {
      server['domain_resolver'] = bootstrapTag;
    }
    final Dict rest = Map<String, dynamic>.of(server)..remove('tag');
    final String key = jsonEncode(rest);
    final String? existing = seen[key];
    if (existing != null) return existing;
    servers.add(server);
    seen[key] = server['tag'] as String;
    return server['tag'] as String;
  }

  addServer(<String, dynamic>{'type': 'local', 'tag': 'dns-local'});

  List<String> addNamedServers(Object? values, String prefix) {
    final List<String> tags = <String>[];
    int index = 0;
    for (final String value in toStrArray(values)) {
      final DnsServerBuild build = parseNameserver(value, '$prefix-${index++}');
      if (build.warning != null) warnings.add(build.warning!);
      if (build.server != null) tags.add(addServer(build.server!));
    }
    return tags;
  }

  final List<String> bootstrapTags =
      addNamedServers(dnsConfig['default-nameserver'], 'dns-bootstrap');
  if (bootstrapTags.isNotEmpty) bootstrapTag = bootstrapTags.first;
  final List<String> proxyServerResolverTags =
      addNamedServers(dnsConfig['proxy-server-nameserver'], 'dns-proxy-server');
  // Only the first `direct-nameserver` entry is honoured, matching the desktop
  // converter. It leaves here as an outbound-scoped resolver rather than as a
  // DNS rule — see [DnsBuild.directDomainResolver].
  final List<String> directResolverTags =
      addNamedServers(dnsConfig['direct-nameserver'], 'dns-direct');

  final Dict hosts = asDict(clash['hosts']);
  final Dict predefined = <String, dynamic>{};
  hosts.forEach((String domain, Object? value) {
    if (domain.isEmpty || _inexactHostPattern.hasMatch(domain)) {
      warnings.add('hosts pattern "$domain" is not an exact domain, skipped');
      return;
    }
    final List<String> addresses = toStrArray(value);
    if (addresses.isEmpty) return;
    predefined[domain] = addresses.length == 1 ? addresses.first : addresses;
  });
  if (predefined.isNotEmpty) {
    servers.add(<String, dynamic>{
      'type': 'hosts',
      'tag': 'dns-hosts',
      'predefined': predefined,
    });
    // sing-box 1.13 legacy response filter: fall through when the hosts server
    // has no matching answer, otherwise use its predefined response.
    rules.insert(0, <String, dynamic>{
      'ip_accept_any': true,
      'server': 'dns-hosts',
    });
  }

  String defaultTag = 'dns-local';
  if (dnsEnabled) {
    final List<String> nameservers = toStrArray(dnsConfig['nameserver']);
    int index = 0;
    for (final String nameserver in nameservers) {
      final DnsServerBuild build = parseNameserver(nameserver, 'dns-$index');
      if (build.warning != null) warnings.add(build.warning!);
      if (build.server != null) {
        final String tag = addServer(build.server!);
        if (defaultTag == 'dns-local' && tag != 'dns-local') defaultTag = tag;
        index++;
      }
    }
    if (defaultTag == 'dns-local' && nameservers.isNotEmpty) {
      warnings.add(
        'No usable DNS nameserver could be converted, falling back to system DNS',
      );
    }

    // nameserver-policy -> dns rules
    final Dict policy = asDict(dnsConfig['nameserver-policy']);
    for (final MapEntry<String, dynamic> entry in policy.entries) {
      final List<String> targets = toStrArray(entry.value);
      if (targets.isEmpty) continue;
      final DnsServerBuild build =
          parseNameserver(targets.first, 'dns-policy-${servers.length}');
      if (build.warning != null) warnings.add(build.warning!);
      if (build.server == null) continue;
      final String tag = addServer(build.server!);
      final DomainPatterns classified =
          classifyDomainPatterns(<String>[entry.key]);
      if (classified.skipped.isNotEmpty) {
        warnings.add(
          'nameserver-policy pattern "${entry.key}" is not supported, skipped',
        );
        continue;
      }
      final Dict fields = domainPatternFields(classified);
      if (fields.isEmpty) continue;
      rules.add(<String, dynamic>{...fields, 'server': tag});
    }

    // fake-ip
    final String enhancedMode =
        strOrElse(toStr(dnsConfig['enhanced-mode']), 'redir-host');
    if (enhancedMode == 'fake-ip') {
      final Dict fakeip = <String, dynamic>{
        'type': 'fakeip',
        'tag': 'dns-fakeip',
        'inet4_range':
            strOrElse(toStr(dnsConfig['fake-ip-range']), '198.18.0.1/16'),
      };
      if (dnsIpv6Enabled) fakeip['inet6_range'] = 'fc00::/18';
      servers.add(fakeip);

      final List<String> filterPatterns =
          toStrArray(dnsConfig['fake-ip-filter']);
      final DomainPatterns classified = classifyDomainPatterns(filterPatterns);
      final Dict filterFields = domainPatternFields(classified);
      final String filterMode =
          strOrElse(toStr(dnsConfig['fake-ip-filter-mode']), 'blacklist');

      if (filterMode == 'whitelist') {
        if (filterFields.isNotEmpty) {
          rules.add(<String, dynamic>{
            ...filterFields,
            'query_type': addressQueryTypes,
            'server': 'dns-fakeip',
          });
        } else {
          warnings.add(
            'fake-ip-filter-mode whitelist with empty filter disables fake-ip',
          );
        }
      } else {
        if (filterFields.isNotEmpty) {
          rules.add(<String, dynamic>{...filterFields, 'server': defaultTag});
        }
        rules.add(<String, dynamic>{
          'query_type': addressQueryTypes,
          'server': 'dns-fakeip',
        });
      }
      if (classified.skipped.isNotEmpty) {
        warnings.add(
          'fake-ip-filter entries not convertible were skipped: '
          '${classified.skipped.join(', ')}',
        );
      }
    }

    if (dnsConfig.containsKey('fallback') &&
        dnsConfig['fallback'] != null &&
        toStrArray(dnsConfig['fallback']).isNotEmpty) {
      warnings.add(
        'dns.fallback / fallback-filter have no sing-box equivalent, skipped',
      );
    }
  }

  final bool hasFakeip =
      servers.any((Dict server) => server['type'] == 'fakeip');
  final Dict dns = compact(<String, dynamic>{
    'servers': servers,
    'rules': rules,
    'final': defaultTag,
    'strategy': dnsIpv6Enabled ? null : 'ipv4_only',
    'independent_cache': hasFakeip ? true : null,
  });

  return DnsBuild(
    dns: dns,
    warnings: warnings,
    defaultDomainResolver: proxyServerResolverTags.isNotEmpty
        ? proxyServerResolverTags.first
        : bootstrapTag,
    directDomainResolver:
        directResolverTags.isNotEmpty ? directResolverTags.first : null,
  );
}
