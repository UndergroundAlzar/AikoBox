/// Pure converter: a merged Clash (mihomo) config map -> a sing-box (1.12+
/// schema) config map.
///
/// Ported from `src/main/core/singbox/convert.ts`.
///
/// * No I/O, no platform channels, no Flutter. Everything is testable.
/// * Unknown or unconvertible options are skipped and reported through
///   `warnings`, never thrown.
/// * An empty profile still yields a valid, startable sing-box config.
///
/// **`errors` is a safety mechanism.** Four situations produce a refusal rather
/// than a best-effort config, because in each one the "best effort" is a
/// configuration that sends the user's traffic out unproxied while looking like
/// it is working:
///
/// ```text
/// profile contains proxy-providers but no inline proxies; refusing to start a direct-only configuration
/// profile contains proxy nodes but none are supported; refusing to start a direct-only configuration
/// group "NAME": no usable members remain; refusing unsafe fallback to "direct"
/// MATCH target "NAME" not found; refusing fallback to direct
/// ```
///
/// These strings are asserted verbatim on both the desktop and the Android
/// side. Do not reword them.
library;

import 'dns.dart';
import 'groups.dart';
import 'inbounds.dart';
import 'models.dart';
import 'outbounds.dart';
import 'primitives.dart';
import 'rules.dart';

const int _defaultControllerPort = 9090;

/// Derives the Clash-API control plane address from the profile.
///
/// The port is honoured; the listen address never is. The control plane hands
/// out the running config and every live connection, so it stays on loopback no
/// matter what the profile asks for.
SingboxController deriveController(Dict clash) {
  final String raw = strOrElse(toStr(clash['external-controller'])?.trim(), '');
  final String secret = strOrElse(toStr(clash['secret']), '');

  int port = _defaultControllerPort;
  if (raw.isNotEmpty) {
    final HostPort parsed = parseHostPort(raw);
    final int? parsedPort = parsed.port;
    if (parsedPort != null && parsedPort > 0 && parsedPort <= 65535) {
      port = parsedPort;
    }
  }

  return SingboxController(
    listen: '127.0.0.1:$port',
    host: '127.0.0.1',
    port: port,
    secret: secret,
  );
}

/// Clash log levels to sing-box log levels.
String mapLogLevel(Object? level) {
  switch (toStr(level)) {
    case 'debug':
      return 'debug';
    case 'warning':
      return 'warn';
    case 'error':
      return 'error';
    case 'silent':
      return 'fatal';
    case 'info':
    default:
      return 'info';
  }
}

/// Top-level Clash keys that sing-box has no analogue for. Presence is
/// reported so the user knows the setting is not silently in effect.
const Map<String, String> kIgnoredTopLevelKeys = <String, String>{
  'unified-delay': 'unified-delay is mihomo-specific, ignored',
  'tcp-concurrent': 'tcp-concurrent is mihomo-specific, ignored',
  'find-process-mode':
      'find-process-mode is mihomo-specific, ignored (process rules still work)',
  'geodata-mode':
      'geodata-mode is mihomo-specific, ignored (rule-sets are used instead)',
  'geo-auto-update': 'geo-auto-update is mihomo-specific, ignored',
  'geox-url': 'geox-url is mihomo-specific, ignored',
  'keep-alive-interval': 'keep-alive-interval is mihomo-specific, ignored',
  'proxy-providers':
      'Clash proxy-providers must be resolved before conversion; unresolved '
          'entries are refused',
  'rule-providers':
      'Clash rule-providers must be resolved before conversion; unresolved '
          'entries are refused',
  'listeners': 'Clash listeners are not supported, ignored',
  'tunnels': 'Clash tunnels are not supported, ignored',
};

const Set<String> _loopbackHosts = <String>{'127.0.0.1', 'localhost', '::1'};

/// Converts a merged Clash config into a sing-box config.
///
/// Never throws for bad input: everything unconvertible comes back through
/// [ConvertResult.warnings], and everything unsafe through
/// [ConvertResult.errors].
ConvertResult convertClashToSingbox(
  Map<String, dynamic> clash, {
  ConvertOptions options = const ConvertOptions(),
}) {
  final List<String> warnings = <String>[];
  final List<String> errors = <String>[];
  final Dict input = asDict(clash);
  final String platform = options.platform;

  final bool ipv6Enabled = toBool(input['ipv6']) != false;
  SingboxController controller = deriveController(input);
  final String requestedController =
      strOrElse(toStr(input['external-controller'])?.trim(), '');
  if (requestedController.isNotEmpty) {
    final String requestedHost =
        parseHostPort(requestedController).host.toLowerCase();
    if (requestedHost.isNotEmpty && !_loopbackHosts.contains(requestedHost)) {
      warnings.add(
        'external-controller was restricted to 127.0.0.1 for desktop security',
      );
    }
  }
  final String? generatedSecret = options.controllerSecret;
  if (controller.secret.isEmpty &&
      generatedSecret != null &&
      generatedSecret.isNotEmpty) {
    controller = controller.copyWith(secret: generatedSecret);
  }

  kIgnoredTopLevelKeys.forEach((String key, String message) {
    final Object? value = input[key];
    if (value == null) return;
    if ((value is Map || value is List) &&
        asDict(value).isEmpty &&
        asArray(value).isEmpty) {
      return;
    }
    if (value == false) return;
    warnings.add(message);
  });

  final Dict proxyProviders = asDict(input['proxy-providers']);
  if (proxyProviders.isNotEmpty && asArray(input['proxies']).isEmpty) {
    errors.add(
      'profile contains proxy-providers but no inline proxies; refusing to '
      'start a direct-only configuration',
    );
  }

  /* ---- outbounds ---- */
  final List<Dict> outbounds = <Dict>[];
  final List<Dict> endpoints = <Dict>[];
  final List<String> proxyTags = <String>[];
  const Set<String> reserved = <String>{'direct', 'GLOBAL'};

  for (final Object? rawProxy in asArray(input['proxies'])) {
    final Dict proxy = asDict(rawProxy);
    final String? name = toStr(proxy['name']);
    if (name != null &&
        name.isNotEmpty &&
        (reserved.contains(name) || proxyTags.contains(name))) {
      warnings.add('proxy "$name": duplicate or reserved name, skipped');
      continue;
    }
    final OutboundBuild build = convertProxy(proxy);
    if (build.warning != null) warnings.add(build.warning!);
    if (build.outbound != null) {
      applyCommonDialFields(build.outbound!, proxy);
      outbounds.add(build.outbound!);
      proxyTags.add(build.outbound!['tag'] as String);
    } else if (build.endpoint != null) {
      applyCommonDialFields(build.endpoint!, proxy);
      endpoints.add(build.endpoint!);
      proxyTags.add(build.endpoint!['tag'] as String);
    }
  }
  if (asArray(input['proxies']).isNotEmpty && proxyTags.isEmpty) {
    errors.add(
      'profile contains proxy nodes but none are supported; refusing to start '
      'a direct-only configuration',
    );
  }

  // dialer-proxy -> detour (second pass, only when the target exists)
  final Set<String> availableTags = proxyTags.toSet();
  for (final Object? rawProxy in asArray(input['proxies'])) {
    final Dict proxy = asDict(rawProxy);
    final String? dialer = toStr(proxy['dialer-proxy']);
    final String? name = toStr(proxy['name']);
    if (dialer == null || dialer.isEmpty || name == null || name.isEmpty) {
      continue;
    }
    Dict? outbound;
    for (final Dict candidate in outbounds) {
      if (candidate['tag'] == name) {
        outbound = candidate;
        break;
      }
    }
    if (outbound != null && availableTags.contains(dialer)) {
      outbound['detour'] = dialer;
    } else if (outbound != null) {
      warnings.add('proxy "$name": dialer-proxy "$dialer" not found, ignored');
    }
  }

  /* ---- groups ---- */
  final List<Dict> groups =
      asArray(input['proxy-groups']).map(asDict).toList();
  final GroupBuild groupBuild =
      convertGroups(groups, proxyTags, availableTags);
  warnings.addAll(groupBuild.warnings);
  errors.addAll(groupBuild.errors);

  /* ---- GLOBAL selector (for clash_mode Global) ---- */
  final bool hasUserGlobal = groupBuild.groupTags.contains('GLOBAL');
  if (!hasUserGlobal) {
    final List<String> globalMembers = <String>[
      ...groupBuild.groupTags,
      ...proxyTags,
      'direct',
    ];
    groupBuild.outbounds.add(<String, dynamic>{
      'type': 'selector',
      'tag': 'GLOBAL',
      'outbounds':
          globalMembers.isNotEmpty ? globalMembers : <String>['direct'],
    });
  }

  /* ---- rules ---- */
  final Set<String> knownOutbounds = <String>{
    'direct',
    'GLOBAL',
    ...proxyTags,
    ...groupBuild.groupTags,
  };
  final List<String> ruleStrings = asArray(input['rules'])
      .map((Object? r) => r is String ? r : jsStringify(r))
      .toList();
  final RulesBuild rulesBuild = convertRules(ruleStrings, knownOutbounds);
  if (ruleStrings.isEmpty && proxyTags.isNotEmpty) {
    rulesBuild.finalOutbound = groupBuild.groupTags.isNotEmpty
        ? groupBuild.groupTags.first
        : proxyTags.first;
    warnings.add(
      'profile has no rules; unmatched traffic will use '
      '"${rulesBuild.finalOutbound}"',
    );
  }
  warnings.addAll(rulesBuild.warnings);
  errors.addAll(rulesBuild.errors);

  /* ---- dns ---- */
  final DnsBuild dnsBuild = buildDns(input, ipv6Enabled: ipv6Enabled);
  warnings.addAll(dnsBuild.warnings);
  final bool dnsEnabled = toBool(asDict(input['dns'])['enable']) == true;

  /* ---- inbounds ---- */
  final InboundsBuild inboundsBuild =
      buildInbounds(input, ipv6Enabled: ipv6Enabled, options: options);
  warnings.addAll(inboundsBuild.warnings);

  /* ---- route rules (actions + clash modes + converted rules) ---- */
  final List<Dict> routeRules =
      buildLanAccessRules(input, inboundsBuild.inbounds, warnings);
  if (toBool(asDict(input['sniffer'])['enable']) == true) {
    routeRules.add(<String, dynamic>{'action': 'sniff'});
  }
  if (dnsEnabled) {
    routeRules
        .add(<String, dynamic>{'protocol': 'dns', 'action': 'hijack-dns'});
  }
  routeRules
      .add(<String, dynamic>{'clash_mode': 'Direct', 'outbound': 'direct'});
  routeRules
      .add(<String, dynamic>{'clash_mode': 'Global', 'outbound': 'GLOBAL'});
  // sing-box only offers the clash_mode values that appear in a rule, so a
  // never-matching placeholder is what keeps "Rule" switchable.
  routeRules.add(<String, dynamic>{
    'clash_mode': 'Rule',
    'domain': <String>['mode-placeholder.aikobox.invalid'],
    'outbound': 'direct',
  });
  routeRules.addAll(rulesBuild.routeRules);

  /* ---- assemble ---- */
  final String mode = strOrElse(toStr(input['mode']), 'rule');
  final Dict profile = asDict(input['profile']);
  final Dict tun = asDict(input['tun']);

  final Dict route = compact(<String, dynamic>{
    'rules': routeRules,
    'rule_set': rulesBuild.ruleSets,
    'final': rulesBuild.finalOutbound,
    'auto_detect_interface': toBool(tun['auto-detect-interface']) ??
        toBool(input['auto-detect-interface']) ??
        true,
    'default_domain_resolver': <String, dynamic>{
      'server': dnsBuild.defaultDomainResolver,
    },
    'default_interface': toStr(input['interface-name']),
    'default_mark': platform.isEmpty || platform == 'linux'
        ? toNum(input['routing-mark'])
        : null,
  });

  final Dict config = <String, dynamic>{
    'log': <String, dynamic>{
      'level': mapLogLevel(input['log-level']),
      'timestamp': true,
    },
    'dns': dnsBuild.dns,
    'inbounds': inboundsBuild.inbounds,
    'outbounds': <Dict>[
      ...outbounds,
      ...groupBuild.outbounds,
      compact(<String, dynamic>{
        'type': 'direct',
        'tag': 'direct',
        'domain_resolver': dnsBuild.directDomainResolver,
      }),
    ],
    'route': route,
    'experimental': <String, dynamic>{
      'clash_api': compact(<String, dynamic>{
        'external_controller': controller.listen,
        'secret': controller.secret.isNotEmpty ? controller.secret : null,
        'default_mode':
            mode.substring(0, 1).toUpperCase() + mode.substring(1).toLowerCase(),
      }),
      'cache_file': <String, dynamic>{
        'enabled': true,
        'store_fakeip': toBool(profile['store-fake-ip']) != false,
      },
    },
  };
  if (endpoints.isNotEmpty) {
    config['endpoints'] = endpoints;
  }

  return ConvertResult(
    config: config,
    warnings: dedupe(warnings),
    errors: dedupe(errors),
    controller: controller,
  );
}
