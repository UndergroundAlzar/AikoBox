/// Port of `src/main/utils/merge.ts`.
///
/// This is the merge a YAML override document performs against a profile, and
/// its key-suffix vocabulary is part of the override format users already write
/// on the desktop:
///
/// ```yaml
/// dns:            # merged key by key into the profile's dns block
///   enable: true
/// dns!:           # replaces the profile's dns block outright
///   enable: false
/// +rules:         # this list goes BEFORE the profile's rules
///   - DOMAIN,a.com,DIRECT
/// rules+:         # this list goes AFTER the profile's rules
///   - MATCH,DIRECT
/// proxies:        # plain list assignment: replaces
///   - {}
/// <weird+key>:    # angle brackets escape a key that really ends in + or !
///   ...
/// ```
library;

/// Deep-merges [patch] into a copy of [target].
///
/// Neither argument is mutated — the desktop mutates in place, which is safe
/// there because the profile object is freshly parsed each time; here the base
/// document is cached and re-used, so mutating it would corrupt the next merge.
///
/// [isOverride] enables the `+list` / `list+` concatenation forms. It is true
/// for override documents and false for plain config merges, exactly as on the
/// desktop.
Map<String, dynamic> deepMerge(
  Map<String, dynamic> target,
  Map<String, dynamic> patch, {
  bool isOverride = false,
}) {
  final result = _cloneMap(target);
  for (final entry in patch.entries) {
    final key = entry.key;
    final value = entry.value;

    if (value is Map) {
      final map = _asStringMap(value);
      if (key.endsWith('!')) {
        result[_trimWrap(key.substring(0, key.length - 1))] = _cloneMap(map);
        continue;
      }
      final plainKey = _trimWrap(key);
      final existing = result[plainKey];
      result[plainKey] = deepMerge(
        existing is Map ? _asStringMap(existing) : <String, dynamic>{},
        map,
        isOverride: isOverride,
      );
      continue;
    }

    if (value is List) {
      if (isOverride && key.startsWith('+')) {
        final plainKey = _trimWrap(key.substring(1));
        final existing = result[plainKey];
        result[plainKey] = <dynamic>[
          ..._cloneList(value),
          if (existing is List) ..._cloneList(existing),
        ];
        continue;
      }
      if (isOverride && key.endsWith('+')) {
        final plainKey = _trimWrap(key.substring(0, key.length - 1));
        final existing = result[plainKey];
        result[plainKey] = <dynamic>[
          if (existing is List) ..._cloneList(existing),
          ..._cloneList(value),
        ];
        continue;
      }
      result[_trimWrap(key)] = _cloneList(value);
      continue;
    }

    // Scalars (and nulls) are assigned under the key verbatim. The desktop
    // does not unwrap angle brackets here either.
    result[key] = value;
  }
  return result;
}

/// `<key>` escapes a key whose real name would otherwise be read as a
/// `!`/`+` directive.
String _trimWrap(String key) =>
    key.length >= 2 && key.startsWith('<') && key.endsWith('>')
    ? key.substring(1, key.length - 1)
    : key;

Map<String, dynamic> _asStringMap(Map<dynamic, dynamic> value) =>
    <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };

Map<String, dynamic> _cloneMap(Map<String, dynamic> value) => <String, dynamic>{
  for (final entry in value.entries) entry.key: _cloneValue(entry.value),
};

List<dynamic> _cloneList(List<dynamic> value) => <dynamic>[
  for (final entry in value) _cloneValue(entry),
];

Object? _cloneValue(Object? value) {
  if (value is Map) return _cloneMap(_asStringMap(value));
  if (value is List) return _cloneList(value);
  return value;
}
