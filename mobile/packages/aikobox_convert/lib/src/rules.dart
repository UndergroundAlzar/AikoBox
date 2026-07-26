/// Clash `rules:` to sing-box `route.rules` + `route.rule_set`.
library;

import 'primitives.dart';

/// Where GEOIP / GEOSITE rule sets are fetched from.
const String kRuleSetUrlBase =
    'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo';

/// Lazily materialises one remote `.srs` rule-set per referenced geo code.
class RuleSetRegistry {
  final Map<String, Dict> _map = <String, Dict>{};

  /// All rule sets referenced so far, in first-reference order.
  List<Dict> get values => _map.values.toList();

  /// Returns the tag for `kind`/`name`, registering the rule set on first use.
  String get(String kind, String name) {
    final String normalized = name.toLowerCase();
    final String tag = '$kind-$normalized';
    _map.putIfAbsent(
      tag,
      () => <String, dynamic>{
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': '$kRuleSetUrlBase/$kind/$normalized.srs',
        'download_detour': 'direct',
      },
    );
    return tag;
  }
}

/// Splits a logical payload `"((A),(B),(C))"` into top-level `"(X)"` chunks.
List<String>? splitLogicalPayload(String payload) {
  final String trimmed = payload.trim();
  if (!trimmed.startsWith('(') || !trimmed.endsWith(')')) return null;
  final String inner = trimmed.substring(1, trimmed.length - 1);
  final List<String> parts = <String>[];
  int depth = 0;
  StringBuffer current = StringBuffer();
  for (final int rune in inner.runes) {
    final String ch = String.fromCharCode(rune);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (depth < 0) return null;
    if (ch == ',' && depth == 0) {
      parts.add(current.toString());
      current = StringBuffer();
      continue;
    }
    current.write(ch);
  }
  parts.add(current.toString());
  return parts
      .map((String part) => part.trim())
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) => part.startsWith('(') && part.endsWith(')')
            ? part.substring(1, part.length - 1).trim()
            : part,
      )
      .toList();
}

/// One converted rule condition, or the reason it is unconvertible.
class ConditionBuild {
  const ConditionBuild({this.fields, this.warning});

  final Dict? fields;
  final String? warning;
}

/// Maps one Clash rule type + payload onto sing-box match fields.
ConditionBuild buildRuleCondition(
  String type,
  String payload,
  RuleSetRegistry ruleSets,
) {
  final String upper = type.toUpperCase();
  switch (upper) {
    case 'DOMAIN':
      return ConditionBuild(
        fields: <String, dynamic>{
          'domain': <String>[payload],
        },
      );
    case 'DOMAIN-SUFFIX':
      return ConditionBuild(
        fields: <String, dynamic>{
          'domain_suffix': <String>[payload],
        },
      );
    case 'DOMAIN-KEYWORD':
      return ConditionBuild(
        fields: <String, dynamic>{
          'domain_keyword': <String>[payload],
        },
      );
    case 'DOMAIN-REGEX':
      return ConditionBuild(
        fields: <String, dynamic>{
          'domain_regex': <String>[payload],
        },
      );
    case 'DOMAIN-WILDCARD':
      return ConditionBuild(
        fields: <String, dynamic>{
          'domain_regex': <String>[wildcardToRegex(payload)],
        },
      );
    case 'IP-CIDR':
    case 'IP-CIDR6':
      return ConditionBuild(
        fields: <String, dynamic>{
          'ip_cidr': <String>[payload],
        },
      );
    case 'SRC-IP-CIDR':
      return ConditionBuild(
        fields: <String, dynamic>{
          'source_ip_cidr': <String>[payload],
        },
      );
    case 'DST-PORT':
      {
        if (payload.contains('-')) {
          return ConditionBuild(
            fields: <String, dynamic>{
              'port_range': <String>[payload.replaceFirst('-', ':')],
            },
          );
        }
        final num? port = toNum(payload);
        if (port == null) {
          return ConditionBuild(warning: 'invalid DST-PORT payload "$payload"');
        }
        return ConditionBuild(
          fields: <String, dynamic>{
            'port': <num>[port],
          },
        );
      }
    case 'SRC-PORT':
      {
        if (payload.contains('-')) {
          return ConditionBuild(
            fields: <String, dynamic>{
              'source_port_range': <String>[payload.replaceFirst('-', ':')],
            },
          );
        }
        final num? port = toNum(payload);
        if (port == null) {
          return ConditionBuild(warning: 'invalid SRC-PORT payload "$payload"');
        }
        return ConditionBuild(
          fields: <String, dynamic>{
            'source_port': <num>[port],
          },
        );
      }
    case 'PROCESS-NAME':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_name': <String>[payload],
        },
      );
    case 'PROCESS-PATH':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_path': <String>[payload],
        },
      );
    case 'PROCESS-PATH-REGEX':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_path_regex': <String>[payload],
        },
      );
    case 'PROCESS-PATH-WILDCARD':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_path_regex': <String>[wildcardToRegex(payload)],
        },
      );
    case 'PROCESS-NAME-REGEX':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_path_regex': <String>[
            r'(?:^|[\\/])(?:'
                '$payload'
                r')$',
          ],
        },
      );
    case 'PROCESS-NAME-WILDCARD':
      return ConditionBuild(
        fields: <String, dynamic>{
          'process_path_regex': <String>[
            r'(?:^|[\\/])' + wildcardToRegex(payload).substring(1),
          ],
        },
      );
    case 'NETWORK':
      return ConditionBuild(
        fields: <String, dynamic>{
          'network': <String>[payload.toLowerCase()],
        },
      );
    case 'GEOSITE':
      return ConditionBuild(
        fields: <String, dynamic>{
          'rule_set': <String>[ruleSets.get('geosite', payload)],
        },
      );
    case 'GEOIP':
      {
        final String code = payload.toLowerCase();
        if (code == 'lan' || code == 'private') {
          return const ConditionBuild(
            fields: <String, dynamic>{'ip_is_private': true},
          );
        }
        return ConditionBuild(
          fields: <String, dynamic>{
            'rule_set': <String>[ruleSets.get('geoip', payload)],
          },
        );
      }
    case 'SRC-GEOIP':
      {
        final String code = payload.toLowerCase();
        if (code == 'lan' || code == 'private') {
          return const ConditionBuild(
            fields: <String, dynamic>{'source_ip_is_private': true},
          );
        }
        return ConditionBuild(
          fields: <String, dynamic>{
            'rule_set': <String>[ruleSets.get('geoip', payload)],
            'rule_set_ip_cidr_match_source': true,
          },
        );
      }
    case 'AND':
    case 'OR':
    case 'NOT':
      {
        final ConditionBuild sub = buildLogicalRule(upper, payload, ruleSets);
        if (sub.warning != null) return ConditionBuild(warning: sub.warning);
        return ConditionBuild(fields: sub.fields);
      }
    default:
      return ConditionBuild(warning: 'rule type "$type" is not supported');
  }
}

/// Builds an `AND` / `OR` / `NOT` rule out of its parenthesised sub-rules.
ConditionBuild buildLogicalRule(
  String mode,
  String payload,
  RuleSetRegistry ruleSets,
) {
  final List<String>? parts = splitLogicalPayload(payload);
  if (parts == null || parts.isEmpty) {
    return ConditionBuild(warning: 'invalid logical rule payload "$payload"');
  }
  final List<Dict> subRules = <Dict>[];
  for (final String part in parts) {
    final int index = part.indexOf(',');
    if (index == -1) {
      return ConditionBuild(warning: 'invalid logical sub-rule "$part"');
    }
    final String subType = part.substring(0, index).trim();
    final String subPayloadFull = part.substring(index + 1).trim();
    // Strip trailing options such as no-resolve on sub-rules.
    final String subPayload =
        const <String>['AND', 'OR', 'NOT'].contains(subType.toUpperCase())
        ? subPayloadFull
        : subPayloadFull.split(',').first.trim();
    final ConditionBuild condition = buildRuleCondition(
      subType,
      subPayload,
      ruleSets,
    );
    if (condition.warning != null || condition.fields == null) {
      return ConditionBuild(
        warning: condition.warning ?? 'invalid logical sub-rule "$part"',
      );
    }
    subRules.add(condition.fields!);
  }

  if (mode == 'NOT') {
    if (subRules.length != 1) {
      return ConditionBuild(
        warning: 'NOT rule must contain exactly one sub-rule: "$payload"',
      );
    }
    return ConditionBuild(
      fields: <String, dynamic>{...subRules.first, 'invert': true},
    );
  }

  return ConditionBuild(
    fields: <String, dynamic>{
      'type': 'logical',
      'mode': mode.toLowerCase(),
      'rules': subRules,
    },
  );
}

/// The converted `route.rules` plus everything they reference.
class RulesBuild {
  RulesBuild();

  final List<Dict> routeRules = <Dict>[];
  List<Dict> ruleSets = <Dict>[];
  String finalOutbound = 'direct';
  final List<String> warnings = <String>[];
  final List<String> errors = <String>[];
}

const Set<String> kRuleOptions = <String>{'no-resolve'};

/// How many top-level comma-separated fields a Clash rule body still carries.
int fieldCount(String body) {
  int count = 1;
  for (int i = 0; i < body.length; i++) {
    if (body[i] == ',') count++;
  }
  return count;
}

/// Peels Clash trailing rule options off the rule body.
///
/// An option is only peeled while the remainder still looks like a complete
/// rule (type, payload, target). Without that guard
/// `IP-CIDR,1.2.3.4/32,no-resolve` — a rule whose target the user simply forgot
/// — would silently lose its last field and be dropped with a warning, where it
/// must instead abort generation with `target "no-resolve" not found or
/// unsupported`. The same guard is what lets a group literally named
/// `no-resolve` keep working.
///
/// sing-box 1.13 has no per-rule resolve flag and never resolves a destination
/// domain while routing, so the option carries no information into the emitted
/// config — peeling it only keeps the rule parseable, and the *absence* of any
/// `{action: "resolve"}` in the output is what makes `no-resolve` semantics
/// hold for every rule.
String splitRuleOptions(String rule) {
  String body = rule;
  for (;;) {
    final int index = body.lastIndexOf(',');
    if (index == -1) break;
    final String option = body.substring(index + 1).trim().toLowerCase();
    if (!kRuleOptions.contains(option)) break;
    final String remainder = body.substring(0, index);
    if (fieldCount(remainder.trim()) < 3) break;
    body = remainder;
  }
  return body.trim();
}

/// True when the condition can only match once the destination domain has been
/// resolved to an address.
bool needsDestinationIp(Dict fields) {
  if (fields['rule_set_ip_cidr_match_source'] == true) return false;
  if (fields['ip_cidr'] != null || fields['ip_is_private'] != null) return true;
  if (toStrArray(
    fields['rule_set'],
  ).any((String tag) => tag.startsWith('geoip-'))) {
    return true;
  }
  return asArray(
    fields['rules'],
  ).any((Object? sub) => needsDestinationIp(asDict(sub)));
}

/// Converts the whole `rules:` list.
RulesBuild convertRules(List<String> rules, Set<String> knownOutbounds) {
  final RulesBuild build = RulesBuild();
  final RuleSetRegistry ruleSets = RuleSetRegistry();

  Dict? mapTarget(String target, String ruleStr) {
    if (target == 'DIRECT') return <String, dynamic>{'outbound': 'direct'};
    if (target == 'REJECT') return <String, dynamic>{'action': 'reject'};
    if (target == 'REJECT-DROP') {
      return <String, dynamic>{'action': 'reject', 'method': 'drop'};
    }
    if (target == 'PASS') {
      build.warnings.add(
        'rule "$ruleStr": PASS has no sing-box equivalent, skipped',
      );
      return null;
    }
    if (knownOutbounds.contains(target)) {
      return <String, dynamic>{'outbound': target};
    }
    build.errors.add(
      'rule "$ruleStr": target "$target" not found or unsupported',
    );
    return null;
  }

  for (final String raw in rules) {
    final String ruleStr = raw.trim();
    if (ruleStr.isEmpty) continue;

    final String body = splitRuleOptions(ruleStr);
    final int firstComma = body.indexOf(',');
    if (firstComma == -1) {
      build.warnings.add('rule "$ruleStr" could not be parsed, skipped');
      continue;
    }
    final String type = body.substring(0, firstComma).trim();
    final String upper = type.toUpperCase();

    if (upper == 'MATCH') {
      final String target = body.substring(firstComma + 1).trim();
      if (target == 'DIRECT') {
        build.finalOutbound = 'direct';
      } else if (target == 'REJECT' || target == 'REJECT-DROP') {
        // An always-reject final: model it as a catch-all reject rule.
        build.routeRules.add(<String, dynamic>{'action': 'reject'});
      } else if (knownOutbounds.contains(target)) {
        build.finalOutbound = target;
      } else {
        build.errors.add(
          'MATCH target "$target" not found; refusing fallback to direct',
        );
      }
      continue;
    }

    if (upper == 'RULE-SET') {
      build.errors.add(
        'rule "$ruleStr": unresolved rule-providers must be resolved before '
        'conversion',
      );
      continue;
    }
    if (upper == 'SUB-RULE') {
      build.warnings.add('rule "$ruleStr": SUB-RULE is not supported, skipped');
      continue;
    }

    final String payload;
    final String target;
    if (upper == 'AND' || upper == 'OR' || upper == 'NOT') {
      final String rest = body.substring(firstComma + 1).trim();
      final int lastComma = rest.lastIndexOf(',');
      if (!rest.startsWith('(') || lastComma == -1) {
        build.warnings.add('rule "$ruleStr" could not be parsed, skipped');
        continue;
      }
      payload = rest.substring(0, lastComma).trim();
      target = rest.substring(lastComma + 1).trim();
    } else {
      final List<String> parts = body.split(',');
      if (parts.length < 3) {
        build.warnings.add('rule "$ruleStr" is incomplete, skipped');
        continue;
      }
      payload = parts[1].trim();
      target = parts[2].trim();
    }

    final ConditionBuild condition = buildRuleCondition(
      type,
      payload,
      ruleSets,
    );
    if (condition.warning != null || condition.fields == null) {
      build.warnings.add(
        'rule "$ruleStr": ${condition.warning ?? 'not convertible'}, skipped',
      );
      continue;
    }
    // An inverted destination-IP condition cannot be expressed in sing-box: the
    // core has no destination address while routing a domain, the inner item
    // fails, and `invertedFailure` turns that failure into a *match*
    // (route/rule/rule_abstract.go:120-172). The rule would therefore catch
    // every domain destination and send it to its target — a silent catch-all,
    // and a silent degrade to direct whenever the target is DIRECT. Drop it.
    if (condition.fields!['invert'] == true &&
        needsDestinationIp(condition.fields!)) {
      build.warnings.add(
        'rule "$ruleStr": an inverted destination-IP condition would match '
        'every domain destination in sing-box, skipped',
      );
      continue;
    }

    final Dict? targetFields = mapTarget(target, ruleStr);
    if (targetFields == null) continue;

    build.routeRules.add(<String, dynamic>{
      ...condition.fields!,
      ...targetFields,
    });
  }

  build.ruleSets = ruleSets.values;
  return build;
}
