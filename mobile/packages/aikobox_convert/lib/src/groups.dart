/// Clash `proxy-groups:` to sing-box `selector` / `urltest` outbounds.
library;

import 'primitives.dart';
import 'safe_regex.dart';

/// The group types sing-box can represent. `relay` is deliberately absent.
const List<String> kSupportedGroupTypes = <String>[
  'select',
  'url-test',
  'fallback',
  'load-balance',
  'smart',
];

/// The result of converting every group in a profile.
class GroupBuild {
  GroupBuild();

  final List<Dict> outbounds = <Dict>[];
  final List<String> groupTags = <String>[];
  final List<String> warnings = <String>[];
  final List<String> errors = <String>[];
}

/// sing-box requires unique outbound tags.
///
/// A group that shadows a proxy node (or the built-in `direct` outbound) emits
/// a second outbound with the same tag. The core rejects the whole config with
/// a message the user cannot act on, so the collision is caught here and
/// reported against the group that caused it.
String? outboundTagCollision(String name, Set<String> proxyTags) {
  if (proxyTags.contains(name)) {
    return 'group "$name": name collides with a proxy node';
  }
  if (name == 'direct') {
    return 'group "$name": name collides with the built-in direct outbound';
  }
  return null;
}

/// Resolves the member list of one group against the proxies and groups that
/// will actually be emitted.
///
/// When nothing survives, this both records a fatal error **and** rewrites the
/// member list to `['direct']`. That pair is deliberate and both halves are
/// load-bearing: the error stops the start, and the placeholder member keeps
/// the emitted JSON structurally valid so diagnostics can still be produced. A
/// caller that ignores `errors` must never be able to ship this group, which is
/// exactly why the error is not downgraded to a warning.
List<String> resolveGroupMembers(
  Dict group,
  String groupName,
  List<String> allProxyNames,
  Set<String> knownTags,
  Set<String> groupNames,
  List<String> warnings,
  List<String> errors,
) {
  List<String> members = toStrArray(group['proxies']);
  if (toBool(group['include-all']) == true ||
      toBool(group['include-all-proxies']) == true) {
    members = <String>[...members, ...allProxyNames];
  }
  if (toStrArray(group['use']).isNotEmpty) {
    errors.add(
      'group "$groupName": unresolved proxy-providers (use) must be resolved '
      'before conversion',
    );
  }

  final String? filter = toStr(group['filter']);
  final String? excludeFilter = toStr(group['exclude-filter']);

  List<String> applyRegex(List<String> list, String pattern, bool keep) {
    try {
      final RegExp regex = compileSafeClashRegexOrThrow(pattern);
      return list
          .where(
            (String name) =>
                keep ? regex.hasMatch(name) : !regex.hasMatch(name),
          )
          .toList();
    } on ClashRegexException catch (error) {
      errors.add(
        'group "$groupName": unsafe or invalid filter (Error: ${error.message})',
      );
      return list;
    } on FormatException catch (error) {
      errors.add(
        'group "$groupName": unsafe or invalid filter (Error: ${error.message})',
      );
      return list;
    }
  }

  final List<String> resolved = <String>[];
  final Set<String> seen = <String>{};
  for (final String raw in members) {
    String name = raw;
    if (name == 'DIRECT') {
      name = 'direct';
    } else if (name == 'REJECT' ||
        name == 'REJECT-DROP' ||
        name == 'PASS' ||
        name == 'COMPATIBLE') {
      warnings.add(
        'group "$groupName": built-in policy "$name" cannot be a sing-box '
        'group member, dropped',
      );
      continue;
    }
    if (seen.contains(name)) continue;
    if (name != 'direct' &&
        !knownTags.contains(name) &&
        !groupNames.contains(name)) {
      warnings.add(
        'group "$groupName": member "$raw" not found or unsupported, dropped',
      );
      continue;
    }
    seen.add(name);
    resolved.add(name);
  }

  List<String> filtered = resolved;
  if (filter != null && filter.isNotEmpty) {
    // A Clash filter targets provider nodes; static members are filtered too,
    // but sub-groups and `direct` are never removed by it.
    filtered = filtered
        .where(
          (String name) =>
              name == 'direct' ||
              groupNames.contains(name) ||
              applyRegex(<String>[name], filter, true).isNotEmpty,
        )
        .toList();
  }
  if (excludeFilter != null && excludeFilter.isNotEmpty) {
    filtered = filtered
        .where(
          (String name) =>
              name == 'direct' ||
              groupNames.contains(name) ||
              applyRegex(<String>[name], excludeFilter, true).isEmpty,
        )
        .toList();
  }

  if (filtered.isEmpty) {
    errors.add(
      'group "$groupName": no usable members remain; refusing unsafe fallback '
      'to "direct"',
    );
    filtered = <String>['direct'];
  }
  return filtered;
}

/// Converts every `proxy-groups:` entry.
GroupBuild convertGroups(
  List<Dict> groups,
  List<String> allProxyNames,
  Set<String> proxyTags,
) {
  final GroupBuild build = GroupBuild();

  // Precompute which groups will actually be emitted so member resolution
  // never references a group that ends up skipped (e.g. relay).
  final Set<String> groupNames = <String>{};
  for (final Dict group in groups) {
    final String? name = toStr(group['name']);
    final String? type = toStr(group['type']);
    if (name != null &&
        name.isNotEmpty &&
        type != null &&
        type.isNotEmpty &&
        kSupportedGroupTypes.contains(type) &&
        !groupNames.contains(name) &&
        outboundTagCollision(name, proxyTags) == null) {
      groupNames.add(name);
    }
  }

  final Set<String> emitted = <String>{};
  for (final Dict group in groups) {
    final String? name = toStr(group['name']);
    if (name == null || name.isEmpty) {
      build.warnings.add('proxy-group without a name was skipped');
      continue;
    }
    if (emitted.contains(name)) {
      build.warnings.add('group "$name": duplicate name, skipped');
      continue;
    }
    final String? type = toStr(group['type']);
    if (type == null || type.isEmpty || !kSupportedGroupTypes.contains(type)) {
      if (type == 'relay') {
        build.warnings.add(
          'group "$name": relay groups are not supported by sing-box, skipped',
        );
      } else {
        build.warnings.add(
          'group "$name": type "${strOrElse(type, 'unknown')}" is not '
          'supported, skipped',
        );
      }
      continue;
    }
    final String? collision = outboundTagCollision(name, proxyTags);
    if (collision != null) {
      build.errors.add(collision);
      continue;
    }

    final Set<String> memberNames = groupNames
        .where((String n) => n != name)
        .toSet();
    final List<String> members = resolveGroupMembers(
      group,
      name,
      allProxyNames,
      proxyTags,
      memberNames,
      build.warnings,
      build.errors,
    );

    if (type == 'select') {
      build.outbounds.add(
        compact(<String, dynamic>{
          'type': 'selector',
          'tag': name,
          'outbounds': members,
        }),
      );
      build.groupTags.add(name);
      emitted.add(name);
    } else {
      if (type == 'fallback') {
        build.warnings.add(
          'group "$name": fallback approximated with url-test',
        );
      } else if (type == 'load-balance') {
        build.warnings.add(
          'group "$name": load-balance approximated with url-test',
        );
      } else if (type == 'smart') {
        build.warnings.add(
          'group "$name": smart groups are not supported, approximated with '
          'url-test',
        );
      }
      final num? interval = toNum(group['interval']);
      build.outbounds.add(
        compact(<String, dynamic>{
          'type': 'urltest',
          'tag': name,
          'outbounds': members,
          'url': toStr(group['url']),
          'interval': interval != null && interval > 0
              ? '${jsNumToString(interval)}s'
              : null,
          'tolerance': toNum(group['tolerance']),
        }),
      );
      build.groupTags.add(name);
      emitted.add(name);
    }
  }

  return build;
}
