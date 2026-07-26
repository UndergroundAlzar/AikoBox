/// The per-profile override document and the code that applies it.
///
/// ## What an overlay is
///
/// The desktop keeps a profile's own YAML pristine and layers two things on top
/// when it generates a runtime config:
///
///  * `rules/<id>.yaml` — `prepend` / `append` / `delete` lists of rule strings
///    (`src/main/core/factory.ts:applyRuleOverride`), and
///  * an override document — a YAML patch deep-merged into the profile
///    (`factory.ts:applyOverrides`).
///
/// Android folds both into one document per profile so there is a single thing
/// to edit, back up and reason about:
///
/// ```yaml
/// rules:
///   prepend:
///     - DOMAIN,intranet.example,DIRECT
///     - 5,DOMAIN-SUFFIX,cdn.example,PROXY   # 5, = insert at index 5
///   append:
///     - MATCH,PROXY
///   delete:
///     - GEOIP,CN,DIRECT
/// patch:
///   dns:
///     enable: true
/// schedule:
///   cron: '0 */6 * * *'
///   fixedInterval: true
/// ```
///
/// The third section, `schedule`, is not an override: it holds the two
/// auto-update settings the desktop has and `ProfileItem` has no field for (a
/// cron expression instead of a plain minute count, and the fixed-interval
/// flag). It lives here so a profile has exactly one sidecar file rather than
/// two, and it is visible in the override editor rather than hidden from it.
///
/// **YAML only.** The desktop refuses JavaScript overrides outright
/// (`override.ts:setOverride`) because a script is not a security boundary;
/// this port never offers the option at all.
library;

import 'deep_merge.dart';
import 'rule_syntax.dart';

/// The rule half of an overlay.
class RuleOverlay {
  const RuleOverlay({
    this.prepend = const <String>[],
    this.append = const <String>[],
    this.delete = const <String>[],
  });

  factory RuleOverlay.fromYaml(Object? node) {
    if (node is! Map) return const RuleOverlay();
    return RuleOverlay(
      prepend: _stringList(node['prepend']),
      append: _stringList(node['append']),
      delete: _stringList(node['delete']),
    );
  }

  static const RuleOverlay empty = RuleOverlay();

  /// Rule strings inserted before the profile's own rules. A `<n>,` prefix
  /// pins the entry to index `n` instead of the top.
  final List<String> prepend;

  /// Rule strings inserted after the profile's own rules. A `<n>,` prefix
  /// counts back from the end.
  final List<String> append;

  /// Rule strings removed from the profile's own rules, matched verbatim.
  final List<String> delete;

  bool get isEmpty => prepend.isEmpty && append.isEmpty && delete.isEmpty;

  bool get isNotEmpty => !isEmpty;

  Map<String, dynamic> toYaml() => <String, dynamic>{
    'prepend': List<String>.of(prepend),
    'append': List<String>.of(append),
    'delete': List<String>.of(delete),
  };

  RuleOverlay copyWith({
    List<String>? prepend,
    List<String>? append,
    List<String>? delete,
  }) => RuleOverlay(
    prepend: prepend ?? this.prepend,
    append: append ?? this.append,
    delete: delete ?? this.delete,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuleOverlay &&
          _sameList(other.prepend, prepend) &&
          _sameList(other.append, append) &&
          _sameList(other.delete, delete);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(prepend),
    Object.hashAll(append),
    Object.hashAll(delete),
  );

  @override
  String toString() =>
      'RuleOverlay(+${prepend.length}/${append.length}/-${delete.length})';
}

/// Auto-update settings the core's `ProfileItem` cannot hold.
class ProfileSchedule {
  const ProfileSchedule({this.cron, this.fixedInterval = false});

  factory ProfileSchedule.fromYaml(Object? node) {
    if (node is! Map) return const ProfileSchedule();
    final cron = node['cron'];
    final fixed = node['fixedInterval'];
    final text = cron?.toString().trim() ?? '';
    return ProfileSchedule(
      cron: text.isEmpty ? null : text,
      fixedInterval: fixed == true || fixed?.toString() == 'true',
    );
  }

  static const ProfileSchedule empty = ProfileSchedule();

  /// A five-field cron expression, or `null` when the profile updates on a
  /// plain minute interval (which `ProfileItem.interval` already holds).
  final String? cron;

  /// The desktop's `allowFixedInterval`: refresh strictly on the period rather
  /// than on the interval the subscription server asks for.
  final bool fixedInterval;

  bool get isEmpty => cron == null && !fixedInterval;

  bool get isNotEmpty => !isEmpty;

  Map<String, dynamic> toYaml() => <String, dynamic>{
    if (cron != null) 'cron': cron,
    if (fixedInterval) 'fixedInterval': true,
  };

  ProfileSchedule copyWith({
    String? cron,
    bool clearCron = false,
    bool? fixedInterval,
  }) => ProfileSchedule(
    cron: clearCron ? null : (cron ?? this.cron),
    fixedInterval: fixedInterval ?? this.fixedInterval,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileSchedule &&
          other.cron == cron &&
          other.fixedInterval == fixedInterval;

  @override
  int get hashCode => Object.hash(cron, fixedInterval);

  @override
  String toString() => 'ProfileSchedule(cron=$cron, fixed=$fixedInterval)';
}

/// Everything layered on one profile.
class ProfileOverlay {
  const ProfileOverlay({
    this.rules = RuleOverlay.empty,
    this.patch = const <String, dynamic>{},
    this.schedule = ProfileSchedule.empty,
  });

  /// Reads the document. A malformed section is treated as absent rather than
  /// fatal — an overlay is user-edited text and half of it being usable beats
  /// refusing to open the editor.
  factory ProfileOverlay.fromYaml(Map<String, dynamic> document) {
    final patch = document['patch'];
    return ProfileOverlay(
      rules: RuleOverlay.fromYaml(document['rules']),
      patch: patch is Map
          ? <String, dynamic>{
              for (final entry in patch.entries)
                entry.key.toString(): entry.value,
            }
          : const <String, dynamic>{},
      schedule: ProfileSchedule.fromYaml(document['schedule']),
    );
  }

  static const ProfileOverlay empty = ProfileOverlay();

  final RuleOverlay rules;

  /// A free-form YAML patch, deep-merged over the profile. Supports the
  /// desktop's `key!`, `+key` and `key+` forms — see [deepMerge].
  final Map<String, dynamic> patch;

  final ProfileSchedule schedule;

  /// True when nothing in this document changes the profile the core reads.
  /// [schedule] is deliberately excluded: it never touches the config, so a
  /// profile that only carries a cron needs no base snapshot.
  bool get changesConfig => rules.isNotEmpty || patch.isNotEmpty;

  bool get isEmpty => !changesConfig && schedule.isEmpty;

  bool get isNotEmpty => !isEmpty;

  Map<String, dynamic> toYaml() => <String, dynamic>{
    if (rules.isNotEmpty) 'rules': rules.toYaml(),
    if (patch.isNotEmpty) 'patch': patch,
    if (schedule.isNotEmpty) 'schedule': schedule.toYaml(),
  };

  ProfileOverlay copyWith({
    RuleOverlay? rules,
    Map<String, dynamic>? patch,
    ProfileSchedule? schedule,
  }) => ProfileOverlay(
    rules: rules ?? this.rules,
    patch: patch ?? this.patch,
    schedule: schedule ?? this.schedule,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileOverlay &&
          other.rules == rules &&
          other.schedule == schedule &&
          _sameYaml(other.patch, patch);

  @override
  int get hashCode => Object.hash(rules, schedule, patch.length);

  @override
  String toString() => 'ProfileOverlay($rules, patch=${patch.keys.toList()})';
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------

/// Normalises a profile's `rules:` node into the flat string form.
///
/// mihomo accepts both `- DOMAIN,a.com,DIRECT` and the sequence form
/// `- [DOMAIN, a.com, DIRECT]`; `factory.ts` joins the latter with commas
/// before comparing, and so does this.
List<String> normaliseRuleList(Object? node) {
  if (node is! List) return <String>[];
  return <String>[
    for (final entry in node)
      if (entry is List)
        entry.map((part) => part?.toString() ?? '').join(',')
      else if (entry != null)
        entry.toString(),
  ];
}

/// The result of splitting overlay rules into "goes at the edge" and "was
/// spliced into the middle at its own offset".
///
/// Port of `factory.ts:processRulesWithOffset`.
({List<String> normalRules, List<String> insertRules}) processRulesWithOffset(
  List<String> ruleStrings,
  List<String> currentRules, {
  bool isAppend = false,
}) {
  final normalRules = <String>[];
  final rules = List<String>.of(currentRules);

  for (final ruleString in ruleStrings) {
    final parts = ruleString.split(',');
    final first = parts.isEmpty ? '' : parts.first.trim();
    final firstIsNumber =
        first.isNotEmpty && parts.length >= 3 && int.tryParse(first) != null;

    if (!firstIsNumber) {
      normalRules.add(ruleString);
      continue;
    }

    final offset = int.parse(first);
    final rule = parts.sublist(1).join(',');
    final position = isAppend
        ? (rules.length - (offset < rules.length ? offset : rules.length))
              .clamp(0, rules.length)
        : (offset < rules.length ? offset : rules.length);
    rules.insert(position, rule);
  }

  return (normalRules: normalRules, insertRules: rules);
}

/// Applies the rule half of an overlay to [baseRules].
/// Port of `factory.ts:applyRuleOverride`.
List<String> applyRuleOverlay(List<String> baseRules, RuleOverlay overlay) {
  var rules = List<String>.of(baseRules);

  if (overlay.prepend.isNotEmpty) {
    final split = processRulesWithOffset(overlay.prepend, rules);
    rules = <String>[...split.normalRules, ...split.insertRules];
  }

  if (overlay.append.isNotEmpty) {
    final split = processRulesWithOffset(
      overlay.append,
      rules,
      isAppend: true,
    );
    rules = <String>[...split.insertRules, ...split.normalRules];
  }

  if (overlay.delete.isNotEmpty) {
    final removed = overlay.delete.toSet();
    rules = rules.where((rule) => !removed.contains(rule)).toList();
  }

  return rules;
}

/// Produces the config the core should actually read: [base] with [overlay]
/// applied. [base] is not modified.
Map<String, dynamic> applyProfileOverlay(
  Map<String, dynamic> base,
  ProfileOverlay overlay,
) {
  var result = Map<String, dynamic>.of(base);

  if (overlay.rules.isNotEmpty) {
    result['rules'] = applyRuleOverlay(
      normaliseRuleList(result['rules']),
      overlay.rules,
    );
  }

  if (overlay.patch.isNotEmpty) {
    result = deepMerge(result, overlay.patch, isOverride: true);
  }

  return result;
}

/// Parses the rules a profile declares, ready for the rules editor.
List<ClashRule> parseProfileRules(Map<String, dynamic> clash) => <ClashRule>[
  for (final raw in normaliseRuleList(clash['rules'])) ClashRule.parse(raw),
];

// ---------------------------------------------------------------------------

List<String> _stringList(Object? node) {
  if (node is! List) return const <String>[];
  return <String>[
    for (final entry in node)
      if (entry != null && entry.toString().trim().isNotEmpty)
        entry.toString(),
  ];
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameYaml(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (!_sameValue(entry.value, b[entry.key])) return false;
  }
  return true;
}

bool _sameValue(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_sameValue(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
