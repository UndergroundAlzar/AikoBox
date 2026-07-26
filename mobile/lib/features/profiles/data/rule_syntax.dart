/// Clash routing-rule grammar: the rule-type table, the payload validators and
/// the string form used inside `rules:` and inside an overlay document.
///
/// Ports `src/renderer/src/components/profiles/edit-rules-modal.tsx`'s
/// `ruleDefinitionsMap` / `parseRuleString` / `convertRuleToString` and the
/// validators from `src/renderer/src/utils/validate.ts`. The desktop leans on
/// the `validator` npm package; the equivalents here are hand-written because
/// there is no Dart port of it in `pubspec.yaml` and the subset actually used
/// is small.
///
/// Every validator answers one question — "would mihomo accept this payload?" —
/// and is deliberately conservative in the same places the desktop is: it is a
/// typo guard in front of the editor, not a parser.
library;

/// One entry of the rule-type table.
class RuleDefinition {
  const RuleDefinition(
    this.name, {
    this.example = '',
    this.noResolve = false,
    this.src = false,
    this.validator,
  });

  final String name;

  /// Shown as the payload field's placeholder.
  final String example;

  /// Whether `no-resolve` is a legal extra parameter for this type.
  final bool noResolve;

  /// Whether `src` is a legal extra parameter for this type.
  final bool src;

  /// `null` means "anything goes" — the desktop treats a missing validator as
  /// unconditionally valid.
  final bool Function(String value)? validator;

  bool accepts(String payload) => validator?.call(payload) ?? true;
}

/// `MATCH` is the catch-all; it carries no payload.
const String kMatchRuleType = 'MATCH';

/// Extra parameters a rule may carry after the outbound.
const String kNoResolveParam = 'no-resolve';
const String kSrcParam = 'src';

/// The rule-type table, in the order the picker shows it.
/// https://wiki.metacubex.one/config/rules/
final Map<String, RuleDefinition> kRuleDefinitions =
    Map<String, RuleDefinition>.unmodifiable(<String, RuleDefinition>{
      'DOMAIN': const RuleDefinition(
        'DOMAIN',
        example: 'example.com',
        validator: isValidDomain,
      ),
      'DOMAIN-SUFFIX': const RuleDefinition(
        'DOMAIN-SUFFIX',
        example: 'example.com',
        validator: isValidDomainSuffix,
      ),
      'DOMAIN-KEYWORD': const RuleDefinition(
        'DOMAIN-KEYWORD',
        example: 'example',
        validator: isValidDomainKeyword,
      ),
      'DOMAIN-REGEX': const RuleDefinition(
        'DOMAIN-REGEX',
        example: 'example.*',
        validator: isValidRegex,
      ),
      'DOMAIN-WILDCARD': const RuleDefinition(
        'DOMAIN-WILDCARD',
        example: '*.google.com',
        validator: isValidDomainWildcard,
      ),
      'GEOSITE': const RuleDefinition(
        'GEOSITE',
        example: 'youtube',
        validator: isValidGeosite,
      ),
      'GEOIP': const RuleDefinition(
        'GEOIP',
        example: 'CN',
        noResolve: true,
        src: true,
        validator: isValidCountryCode,
      ),
      'SRC-GEOIP': const RuleDefinition(
        'SRC-GEOIP',
        example: 'CN',
        validator: isValidCountryCode,
      ),
      'IP-ASN': const RuleDefinition(
        'IP-ASN',
        example: '13335',
        noResolve: true,
        src: true,
        validator: isValidAsn,
      ),
      'SRC-IP-ASN': const RuleDefinition(
        'SRC-IP-ASN',
        example: '9808',
        validator: isValidAsn,
      ),
      'IP-CIDR': const RuleDefinition(
        'IP-CIDR',
        example: '127.0.0.0/8',
        noResolve: true,
        src: true,
        validator: isValidIpCidr,
      ),
      'IP-CIDR6': const RuleDefinition(
        'IP-CIDR6',
        example: '2620:0:2d0:200::7/32',
        noResolve: true,
        src: true,
        validator: isValidIpCidr,
      ),
      'SRC-IP-CIDR': const RuleDefinition(
        'SRC-IP-CIDR',
        example: '192.168.1.201/32',
        validator: isValidIpCidr,
      ),
      'IP-SUFFIX': const RuleDefinition(
        'IP-SUFFIX',
        example: '8.8.8.8/24',
        noResolve: true,
        src: true,
        validator: isValidIpCidr,
      ),
      'SRC-IP-SUFFIX': const RuleDefinition(
        'SRC-IP-SUFFIX',
        example: '192.168.1.201/8',
        validator: isValidIpCidr,
      ),
      'SRC-PORT': const RuleDefinition(
        'SRC-PORT',
        example: '7777',
        validator: isValidPortRange,
      ),
      'DST-PORT': const RuleDefinition(
        'DST-PORT',
        example: '80',
        validator: isValidPortRange,
      ),
      'IN-PORT': const RuleDefinition(
        'IN-PORT',
        example: '7897',
        validator: isValidPortRange,
      ),
      'DSCP': const RuleDefinition('DSCP', example: '4', validator: isValidDscp),
      // The desktop switches these examples on `platform`; Android's answer to
      // "what does a process look like" is a package name.
      'PROCESS-NAME': const RuleDefinition(
        'PROCESS-NAME',
        example: 'com.android.chrome',
        validator: isValidProcessName,
      ),
      'PROCESS-PATH': const RuleDefinition(
        'PROCESS-PATH',
        example: '/system/bin/ping',
        validator: isValidProcessPath,
      ),
      'PROCESS-NAME-WILDCARD': const RuleDefinition(
        'PROCESS-NAME-WILDCARD',
        example: '*telegram*',
        validator: isValidProcessNameWildcard,
      ),
      'PROCESS-NAME-REGEX': const RuleDefinition(
        'PROCESS-NAME-REGEX',
        example: '.*telegram.*',
        validator: isValidRegex,
      ),
      'PROCESS-PATH-WILDCARD': const RuleDefinition(
        'PROCESS-PATH-WILDCARD',
        example: '/data/*/lib/*',
        validator: isValidProcessPathWildcard,
      ),
      'PROCESS-PATH-REGEX': const RuleDefinition(
        'PROCESS-PATH-REGEX',
        example: '.*bin/ping',
        validator: isValidRegex,
      ),
      'NETWORK': const RuleDefinition(
        'NETWORK',
        example: 'udp',
        validator: isValidNetwork,
      ),
      'UID': const RuleDefinition('UID', example: '1001', validator: isValidUid),
      'IN-TYPE': const RuleDefinition(
        'IN-TYPE',
        example: 'SOCKS/HTTP',
        validator: isValidInboundType,
      ),
      'IN-USER': const RuleDefinition(
        'IN-USER',
        example: 'mihomo',
        validator: isValidInboundUser,
      ),
      'IN-NAME': const RuleDefinition(
        'IN-NAME',
        example: 'ss',
        validator: isValidIdentifier,
      ),
      'SUB-RULE': const RuleDefinition(
        'SUB-RULE',
        example: '(NETWORK,tcp)',
        validator: isValidSubRule,
      ),
      'RULE-SET': const RuleDefinition(
        'RULE-SET',
        example: 'providername',
        noResolve: true,
        src: true,
        validator: isValidIdentifier,
      ),
      'AND': const RuleDefinition(
        'AND',
        example: '((DOMAIN,baidu.com),(NETWORK,UDP))',
        validator: isValidLogicRule,
      ),
      'OR': const RuleDefinition(
        'OR',
        example: '((NETWORK,UDP),(DOMAIN,baidu.com))',
        validator: isValidLogicRule,
      ),
      'NOT': const RuleDefinition(
        'NOT',
        example: '((DOMAIN,baidu.com))',
        validator: isValidLogicRule,
      ),
      kMatchRuleType: const RuleDefinition(kMatchRuleType),
    });

/// Rule types in picker order.
final List<String> kRuleTypes = List<String>.unmodifiable(
  kRuleDefinitions.keys,
);

/// Outbounds mihomo always understands, appended to the profile's own groups.
const List<String> kBuiltinOutbounds = <String>[
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'PASS',
  'COMPATIBLE',
];

RuleDefinition? ruleDefinition(String type) => kRuleDefinitions[type];

bool ruleSupportsNoResolve(String type) =>
    kRuleDefinitions[type]?.noResolve ?? false;

bool ruleSupportsSrc(String type) => kRuleDefinitions[type]?.src ?? false;

String ruleExample(String type) => kRuleDefinitions[type]?.example ?? '';

/// Whether [payload] is acceptable for [type]. Unknown types and `MATCH`
/// accept anything, matching the desktop.
bool validateRulePayload(String type, String payload) {
  if (type == kMatchRuleType) return true;
  return kRuleDefinitions[type]?.accepts(payload) ?? true;
}

// ---------------------------------------------------------------------------
// The rule string
// ---------------------------------------------------------------------------

/// One routing rule, in the shape the editor manipulates it.
///
/// [offset] is the overlay-only prefix that says *where* a prepended or
/// appended rule belongs relative to the profile's own rules: `3,DOMAIN,a,b`
/// prepends at index 3 rather than at the top. It is never present in a
/// profile's own `rules:` list.
class ClashRule {
  const ClashRule({
    required this.type,
    this.payload = '',
    this.proxy = '',
    this.params = const <String>[],
    this.offset,
  });

  /// Parses one `rules:` entry.
  ///
  /// A leading purely-numeric field is an offset, but only when at least three
  /// fields follow it — otherwise `1234,DIRECT` would be read as an offset
  /// instead of a (nonsensical but possible) rule type. Same guard as the
  /// desktop's `firstPartIsNumber`.
  factory ClashRule.parse(String raw) {
    final parts = raw.split(',');
    var fields = parts;
    var offset = 0;

    final first = parts.isEmpty ? '' : parts.first.trim();
    final firstIsNumber =
        first.isNotEmpty && parts.length >= 3 && int.tryParse(first) != null;
    if (firstIsNumber) {
      offset = int.parse(first);
      fields = parts.sublist(1);
    }

    String at(int index) => index < fields.length ? fields[index] : '';

    if (at(0) == kMatchRuleType) {
      return ClashRule(
        type: kMatchRuleType,
        proxy: at(1),
        offset: offset > 0 ? offset : null,
      );
    }
    return ClashRule(
      type: at(0),
      payload: at(1),
      proxy: at(2),
      params: <String>[
        if (fields.length > 3)
          for (final param in fields.sublist(3))
            if (param.trim().isNotEmpty) param,
      ],
      offset: offset > 0 ? offset : null,
    );
  }

  final String type;
  final String payload;
  final String proxy;

  /// `no-resolve`, `src`, … in the order they appeared.
  final List<String> params;

  /// Insert position for an overlay rule. `null` means "top" for a prepend and
  /// "bottom" for an append.
  final int? offset;

  bool get isMatch => type == kMatchRuleType;

  /// The `rules:` string form, offset included.
  String format() {
    final parts = <String>[
      type,
      if (payload.isNotEmpty) payload,
      if (proxy.isNotEmpty) proxy,
      ...params,
    ];
    if (offset != null && offset! > 0) {
      parts.insert(0, offset!.toString());
    }
    return parts.join(',');
  }

  /// The string form without the offset — what a `delete:` entry has to be so
  /// it matches an entry of the profile's own `rules:` list exactly.
  String formatWithoutOffset() => copyWith(clearOffset: true).format();

  ClashRule copyWith({
    String? type,
    String? payload,
    String? proxy,
    List<String>? params,
    int? offset,
    bool clearOffset = false,
  }) => ClashRule(
    type: type ?? this.type,
    payload: payload ?? this.payload,
    proxy: proxy ?? this.proxy,
    params: params ?? this.params,
    offset: clearOffset ? null : (offset ?? this.offset),
  );

  /// True when the type, payload, outbound and extra parameters all match —
  /// the identity a `delete:` entry uses to find its victim.
  bool sameRuleAs(ClashRule other) =>
      type == other.type &&
      payload == other.payload &&
      proxy == other.proxy &&
      params.length == other.params.length &&
      _listEquals(params, other.params);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClashRule && other.offset == offset && sameRuleAs(other);

  @override
  int get hashCode =>
      Object.hash(type, payload, proxy, offset, Object.hashAll(params));

  @override
  String toString() => 'ClashRule(${format()})';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether the "add rule" button should be enabled.
/// Port of `isAddRuleDisabled`, inverted.
bool canAddRule(ClashRule rule) {
  if (rule.type.isEmpty || rule.proxy.isEmpty) return false;
  if (!rule.isMatch && rule.payload.trim().isEmpty) return false;
  if (!rule.isMatch && !validateRulePayload(rule.type, rule.payload)) {
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Validators
// ---------------------------------------------------------------------------

// Written with escapes rather than literal characters so the source file's
// encoding can never change what these match.
final RegExp _fqdnPart = RegExp(
  '^[a-z_¡-￿0-9-]+\$',
  caseSensitive: false,
);
final RegExp _fullWidth = RegExp('[\uff01-\uff5e]');
final RegExp _fqdnTld = RegExp(
  '^([a-z¡-￿]{2,}|xn[a-z0-9-]{2,})\$',
  caseSensitive: false,
);
final RegExp _digits = RegExp(r'^\d+$');
final RegExp _alpha = RegExp(r'^[A-Za-z]+$');
final RegExp _alphanumeric = RegExp(r'^[A-Za-z0-9]+$');
final RegExp _domainWildcardChars = RegExp(r'^[a-zA-Z0-9.*?-]+$');
final RegExp _processNameChars = RegExp(r'^[a-zA-Z0-9\-_.]+$');
final RegExp _androidPackage = RegExp(
  r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
  caseSensitive: false,
);
final RegExp _unixPath = RegExp(r'^/');
final RegExp _windowsPath = RegExp(r'^[a-zA-Z]:[\\/].+');
final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

/// `validator.isFQDN(value, {require_tld: true, allow_wildcard})`.
bool isFqdn(String value, {bool allowWildcard = false}) {
  var text = value;
  if (allowWildcard && text.startsWith('*.')) {
    text = text.substring(2);
  }
  final parts = text.split('.');
  if (parts.length < 2) return false;
  final tld = parts.last;
  if (!_fqdnTld.hasMatch(tld)) return false;
  if (_digits.hasMatch(tld)) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 63) return false;
    if (!_fqdnPart.hasMatch(part)) return false;
    if (_fullWidth.hasMatch(part)) return false;
    if (part.startsWith('-') || part.endsWith('-')) return false;
    if (part.contains('_')) return false;
  }
  return true;
}

bool isValidDomain(String value) {
  if (value.length > 253 || value.length < 2) return false;
  if (isFqdn(value)) return true;
  return const <String>{
    'localhost',
    'local',
    'localdomain',
  }.contains(value.toLowerCase());
}

bool isValidDomainSuffix(String value) => isFqdn(value, allowWildcard: true);

bool isValidDomainKeyword(String value) {
  if (value.isEmpty) return false;
  const allowed =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._';
  return value.split('').every(allowed.contains);
}

bool isValidRegex(String value) {
  try {
    RegExp(value);
    return true;
  } catch (_) {
    return false;
  }
}

bool isValidDomainWildcard(String value) {
  if (value.isEmpty) return false;
  if (!_domainWildcardChars.hasMatch(value)) return false;
  final withoutWildcards = value.replaceAll('*', 'a').replaceAll('?', 'a');
  return withoutWildcards.contains('.');
}

/// `validator.isAlphanumeric(value, 'en-US', {ignore})`.
bool _isAlphanumericIgnoring(String value, String ignore) {
  final stripped = value.split('').where((c) => !ignore.contains(c)).join();
  return stripped.isNotEmpty && _alphanumeric.hasMatch(stripped);
}

bool isValidGeosite(String value) => _isAlphanumericIgnoring(value, '-_');

/// Also used for `RULE-SET` and `IN-NAME`: letters, digits, `-` and `_`.
bool isValidIdentifier(String value) => _isAlphanumericIgnoring(value, '-_');

bool isValidCountryCode(String value) =>
    value.length == 2 && _alpha.hasMatch(value);

bool _isIntInRange(String value, int min, int max) {
  if (!_digits.hasMatch(value)) return false;
  final parsed = int.tryParse(value);
  return parsed != null && parsed >= min && parsed <= max;
}

bool isValidAsn(String value) => _isIntInRange(value, 1, 4294967295);

bool isValidUid(String value) => _isIntInRange(value, 0, 65535);

bool isValidDscp(String value) => _isIntInRange(value, 0, 63);

bool isValidPort(String value) => _isIntInRange(value, 0, 65535);

bool isValidPortRange(String value) {
  if (value.contains('-')) {
    final bounds = value.split('-');
    if (bounds.length != 2) return false;
    if (!isValidPort(bounds[0]) || !isValidPort(bounds[1])) return false;
    return int.parse(bounds[0]) <= int.parse(bounds[1]);
  }
  return isValidPort(value);
}

bool isValidNetwork(String value) =>
    const <String>{'tcp', 'udp'}.contains(value.toLowerCase());

bool isValidIpv4(String value) {
  final match = _ipv4.firstMatch(value);
  if (match == null) return false;
  for (var group = 1; group <= 4; group++) {
    final octet = match.group(group)!;
    // validator.js rejects "01"; so does mihomo's parser.
    if (octet.length > 1 && octet.startsWith('0')) return false;
    final number = int.parse(octet);
    if (number > 255) return false;
  }
  return true;
}

bool isValidIpv6(String value) {
  if (value.isEmpty || !value.contains(':')) return false;
  var text = value;
  // A trailing IPv4 form (::ffff:192.0.2.1) counts as two 16-bit groups.
  var tailGroups = 0;
  final lastColon = text.lastIndexOf(':');
  final tail = text.substring(lastColon + 1);
  if (tail.contains('.')) {
    if (!isValidIpv4(tail)) return false;
    tailGroups = 2;
    text = text.substring(0, lastColon + 1);
    if (text.endsWith(':') && !text.endsWith('::')) {
      text = text.substring(0, text.length - 1);
    }
  }

  final compressed = text.split('::');
  if (compressed.length > 2) return false;

  int? countGroups(String part) {
    if (part.isEmpty) return 0;
    var total = 0;
    for (final group in part.split(':')) {
      if (group.isEmpty) return null;
      if (group.length > 4) return null;
      if (int.tryParse(group, radix: 16) == null) return null;
      total++;
    }
    return total;
  }

  if (compressed.length == 2) {
    final head = countGroups(compressed[0]);
    final rest = countGroups(compressed[1]);
    if (head == null || rest == null) return false;
    return head + rest + tailGroups <= 7;
  }
  final groups = countGroups(compressed[0]);
  if (groups == null) return false;
  return groups + tailGroups == 8;
}

bool isValidIpCidr(String value) {
  final slash = value.indexOf('/');
  if (slash <= 0) return false;
  final address = value.substring(0, slash);
  final prefix = value.substring(slash + 1);
  if (!_digits.hasMatch(prefix)) return false;
  final bits = int.parse(prefix);
  if (isValidIpv4(address)) return bits >= 0 && bits <= 32;
  if (isValidIpv6(address)) return bits >= 0 && bits <= 128;
  return false;
}

bool isValidProcessPath(String value) {
  if (value.isEmpty) return false;
  return _windowsPath.hasMatch(value) ||
      _unixPath.hasMatch(value) ||
      _androidPackage.hasMatch(value);
}

bool isValidProcessPathWildcard(String value) {
  if (value.isEmpty) return false;
  return isValidProcessPath(
    value.replaceAll('*', 'a').replaceAll('?', 'a'),
  );
}

bool isValidProcessName(String value) {
  if (value.isEmpty) return false;
  return _processNameChars.hasMatch(value) || _androidPackage.hasMatch(value);
}

bool isValidProcessNameWildcard(String value) {
  if (value.isEmpty) return false;
  return isValidProcessName(
    value.replaceAll('*', 'a').replaceAll('?', 'a'),
  );
}

bool isValidInboundType(String value) {
  const known = <String>{
    'http',
    'https',
    'socks',
    'socks4',
    'socks5',
    'tproxy',
    'redir',
    'mixed',
  };
  final types = value.split('/');
  return types.isNotEmpty &&
      types.every((type) => known.contains(type.toLowerCase()));
}

bool isValidInboundUser(String value) {
  if (value.isEmpty) return false;
  return value
      .split('/')
      .every((user) => user.isNotEmpty && _isAlphanumericIgnoring(user, '-_.'));
}

bool isValidLogicRule(String value) {
  if (value.isEmpty) return false;
  var depth = 0;
  for (final rune in value.runes) {
    if (rune == 0x28) depth++;
    if (rune == 0x29) depth--;
    if (depth < 0) return false;
  }
  return depth == 0 && value.startsWith('(') && value.endsWith(')');
}

bool isValidSubRule(String value) {
  if (value.isEmpty) return false;
  if (value.startsWith('(') && value.endsWith(')')) {
    return isValidLogicRule(value);
  }
  return isValidIdentifier(value);
}
