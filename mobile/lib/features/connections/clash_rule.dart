/// "Copy as Clash rule" generation.
///
/// Port of the `CopyableSettingItem` menu inside
/// `src/renderer/src/components/connections/connection-detail-modal.tsx`. The
/// strings this produces are pasted straight into a user's `rules:` block, so
/// they have to match the desktop byte for byte — a `DOMAIN-SUFFIX` list that
/// silently drops the apex, or an `IP-CIDR` without its `/32`, is a rule that
/// looks right and never matches.
///
/// Everything here is pure and string-in/string-out; the sheet that renders it
/// supplies the labels.
library;

import 'package:flutter/foundation.dart';

/// Clash rule prefixes this app can generate.
///
/// Only the ones reachable from the metadata `ConnectionInfo` actually carries
/// are listed. `IP-ASN` / `SRC-IP-ASN` handling is kept because the desktop has
/// it and the transform is part of the ported contract, even though sing-box's
/// clash_api does not currently report ASNs.
abstract final class ClashRulePrefix {
  static const String domain = 'DOMAIN';
  static const String domainSuffix = 'DOMAIN-SUFFIX';
  static const String ipCidr = 'IP-CIDR';
  static const String srcIpCidr = 'SRC-IP-CIDR';
  static const String ipAsn = 'IP-ASN';
  static const String srcIpAsn = 'SRC-IP-ASN';
  static const String processName = 'PROCESS-NAME';
  static const String dstPort = 'DST-PORT';
  static const String srcPort = 'SRC-PORT';
  static const String network = 'NETWORK';
  static const String inType = 'IN-TYPE';
}

/// One `(prefix, value)` pair to expand into rule text.
@immutable
class ClashRuleTarget {
  const ClashRuleTarget(this.prefix, this.value);

  final String prefix;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClashRuleTarget &&
          other.prefix == prefix &&
          other.value == value;

  @override
  int get hashCode => Object.hash(prefix, value);

  @override
  String toString() => 'ClashRuleTarget($prefix, $value)';
}

/// One entry of the copy menu.
@immutable
class ClashRuleCandidate {
  const ClashRuleCandidate({required this.text, required this.isRaw});

  /// Exactly what lands on the clipboard.
  final String text;

  /// True for the leading "copy the value as it is shown" entry.
  final bool isRaw;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClashRuleCandidate && other.text == text && other.isRaw == isRaw;

  @override
  int get hashCode => Object.hash(text, isRaw);

  @override
  String toString() => 'ClashRuleCandidate($text, raw: $isRaw)';
}

/// True when [value] looks like an IPv6 literal, by the desktop's test: it
/// contains a colon.
bool isIpv6Literal(String value) => value.contains(':');

/// Every suffix of [domain] that is worth a `DOMAIN-SUFFIX` rule.
///
/// Port of `getSubDomains`. A two-label name is returned unchanged; anything
/// longer yields each progressively shorter suffix **except** the last one, so
/// `a.b.example.com` gives `a.b.example.com`, `b.example.com`, `example.com`
/// and never the bare TLD `com`.
List<String> clashDomainSuffixes(String domain) {
  final List<String> parts = domain.split('.');
  if (parts.length <= 2) return <String>[domain];
  final List<String> suffixes = <String>[
    for (int i = 0; i < parts.length; i++) parts.sublist(i).join('.'),
  ];
  return suffixes.sublist(0, suffixes.length - 1);
}

/// The rule text for one `(prefix, value)` pair, or several for
/// `DOMAIN-SUFFIX`.
List<String> clashRuleTextsFor(String prefix, String value) {
  if (prefix.isEmpty || value.isEmpty) return const <String>[];

  if (prefix == ClashRulePrefix.domainSuffix) {
    return <String>[
      for (final String suffix in clashDomainSuffixes(value)) '$prefix,$suffix',
    ];
  }

  if (prefix == ClashRulePrefix.ipAsn || prefix == ClashRulePrefix.srcIpAsn) {
    // The core reports an ASN as "1234 Some Org"; only the number is a rule.
    return <String>['$prefix,${value.split(' ').first}'];
  }

  if (prefix == ClashRulePrefix.ipCidr || prefix == ClashRulePrefix.srcIpCidr) {
    // A bare address is not a CIDR. The desktop pins it to a single host.
    return <String>['$prefix,$value${isIpv6Literal(value) ? '/128' : '/32'}'];
  }

  return <String>['$prefix,$value'];
}

/// The full copy menu for one detail row.
///
/// The first entry is always [displayValue] verbatim — the desktop's `raw`
/// item — followed by one entry per generated rule. Exact duplicates are
/// dropped (a single-label host makes `DOMAIN` and `DOMAIN-SUFFIX` collapse
/// onto each other's text) so the menu never shows the same line twice.
List<ClashRuleCandidate> clashRuleCandidates({
  required String displayValue,
  List<ClashRuleTarget> targets = const <ClashRuleTarget>[],
}) {
  final List<ClashRuleCandidate> out = <ClashRuleCandidate>[];
  final Set<String> seen = <String>{};

  if (displayValue.isNotEmpty) {
    out.add(ClashRuleCandidate(text: displayValue, isRaw: true));
    seen.add(displayValue);
  }

  for (final ClashRuleTarget target in targets) {
    for (final String text in clashRuleTextsFor(target.prefix, target.value)) {
      if (seen.add(text)) {
        out.add(ClashRuleCandidate(text: text, isRaw: false));
      }
    }
  }

  return List<ClashRuleCandidate>.unmodifiable(out);
}
