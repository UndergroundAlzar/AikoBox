/// The rules editor's working state.
///
/// Port of the state machine inside
/// `src/renderer/src/components/profiles/edit-rules-modal.tsx`. The editor
/// shows one flat list — the profile's own rules with the overlay already
/// folded in — and remembers, per index, whether that row came from a
/// `prepend`, an `append`, or is marked for deletion. Saving turns those three
/// index sets back into a [RuleOverlay].
///
/// Kept as a pure immutable value so the fiddly parts (index bookkeeping across
/// insertions and swaps) can be tested without a widget tree.
library;

import 'rule_overlay.dart';
import 'rule_syntax.dart';

/// How a row in the editor should be drawn.
enum RuleRowState {
  /// Comes from the profile itself and is untouched.
  original,

  /// Added by the overlay.
  added,

  /// Marked for removal; drawn struck through.
  deleted,
}

/// One row as the list renders it.
class RuleRow {
  const RuleRow({
    required this.index,
    required this.rule,
    required this.state,
  });

  /// Position in [RuleEditorState.rules]. Stable for the lifetime of one state
  /// object; every mutation returns a new state with fresh indices.
  final int index;
  final ClashRule rule;
  final RuleRowState state;

  bool get isDeleted => state == RuleRowState.deleted;
  bool get isAdded => state == RuleRowState.added;
}

/// The editor's whole state.
class RuleEditorState {
  RuleEditorState({
    required List<ClashRule> rules,
    Set<int> prepend = const <int>{},
    Set<int> append = const <int>{},
    Set<int> deleted = const <int>{},
  }) : rules = List<ClashRule>.unmodifiable(rules),
       prepend = Set<int>.unmodifiable(prepend),
       append = Set<int>.unmodifiable(append),
       deleted = Set<int>.unmodifiable(deleted);

  /// Rebuilds the merged view from a profile's own rules plus its overlay.
  ///
  /// Mirrors the desktop's load path exactly, including the quirk that a
  /// `delete:` entry only marks the *first* matching row.
  factory RuleEditorState.load(
    List<ClashRule> baseRules,
    RuleOverlay overlay,
  ) {
    var rules = List<ClashRule>.of(baseRules);
    final prepend = <int>{};
    final append = <int>{};
    final deleted = <int>{};

    if (overlay.prepend.isNotEmpty) {
      final result = _spliceAll(
        rules,
        overlay.prepend.map(ClashRule.parse).toList(growable: false),
        (rule, current) => rule.offset != null && rule.offset! < current.length
            ? rule.offset!
            : 0,
      );
      rules = result.rules;
      prepend.addAll(result.indices);
    }

    if (overlay.append.isNotEmpty) {
      final result = _spliceAll(
        rules,
        overlay.append.map(ClashRule.parse).toList(growable: false),
        (rule, current) => rule.offset != null
            ? (current.length - rule.offset!).clamp(0, current.length)
            : current.length,
      );
      rules = result.rules;
      // The desktop forgets this step, so an `append` carrying an offset that
      // lands above a `prepend` row silently mislabels it. Splicing shifts
      // every index at or after the insertion point, prepends included.
      _shiftAllBy(prepend, result.insertions);
      append.addAll(result.indices.where((index) => !prepend.contains(index)));
    }

    // Only the first match is marked, exactly as on the desktop: a `delete`
    // entry names a rule, and a profile that repeats a rule verbatim keeps the
    // later copies.
    for (final entry in overlay.delete) {
      final target = ClashRule.parse(entry);
      final match = rules.indexWhere((rule) => rule.sameRuleAs(target));
      if (match != -1) deleted.add(match);
    }

    return RuleEditorState(
      rules: rules,
      prepend: prepend,
      append: append,
      deleted: deleted,
    );
  }

  /// The merged rule list, top to bottom.
  final List<ClashRule> rules;

  /// Indices of rows the overlay prepends.
  final Set<int> prepend;

  /// Indices of rows the overlay appends.
  final Set<int> append;

  /// Indices of rows marked for deletion.
  final Set<int> deleted;

  int get length => rules.length;

  /// True when saving would write a non-empty overlay.
  bool get hasChanges =>
      prepend.isNotEmpty || append.isNotEmpty || deleted.isNotEmpty;

  RuleRowState stateOf(int index) {
    if (deleted.contains(index)) return RuleRowState.deleted;
    if (prepend.contains(index) || append.contains(index)) {
      return RuleRowState.added;
    }
    return RuleRowState.original;
  }

  /// Every row, in display order.
  List<RuleRow> rows() => <RuleRow>[
    for (var index = 0; index < rules.length; index++)
      RuleRow(index: index, rule: rules[index], state: stateOf(index)),
  ];

  /// Rows whose type, payload, outbound or extra parameters contain [query],
  /// case-insensitively. An empty query matches everything.
  List<RuleRow> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return rows();
    return rows().where((row) {
      final rule = row.rule;
      return rule.type.toLowerCase().contains(needle) ||
          rule.payload.toLowerCase().contains(needle) ||
          rule.proxy.toLowerCase().contains(needle) ||
          rule.params.any((param) => param.toLowerCase().contains(needle));
    }).toList(growable: false);
  }

  /// Inserts [rule] as a prepend (top, or at its own offset) or an append
  /// (bottom, or `offset` rows up from the bottom).
  RuleEditorState insert(ClashRule rule, {required bool asPrepend}) {
    final position = asPrepend
        ? (rule.offset != null
              ? rule.offset!.clamp(0, rules.length)
              : 0)
        : (rule.offset != null
              ? (rules.length - rule.offset!).clamp(0, rules.length)
              : rules.length);

    final next = List<ClashRule>.of(rules)..insert(position, rule);
    final nextPrepend = _shifted(prepend, position);
    final nextAppend = _shifted(append, position);
    final nextDeleted = _shifted(deleted, position);
    if (asPrepend) {
      nextPrepend.add(position);
    } else {
      nextAppend.add(position);
    }

    return RuleEditorState(
      rules: next,
      prepend: nextPrepend,
      append: nextAppend,
      deleted: nextDeleted,
    );
  }

  /// Marks [index] for deletion, or clears the mark if it already carries one.
  RuleEditorState toggleDelete(int index) {
    if (index < 0 || index >= rules.length) return this;
    final next = Set<int>.of(deleted);
    if (!next.remove(index)) next.add(index);
    return RuleEditorState(
      rules: rules,
      prepend: prepend,
      append: append,
      deleted: next,
    );
  }

  RuleEditorState moveUp(int index) => _swap(index, index - 1);

  RuleEditorState moveDown(int index) => _swap(index, index + 1);

  /// Swaps two adjacent rows, keeping the overlay offsets pointing at the same
  /// place. Only adjacent swaps are meaningful — the offset arithmetic assumes
  /// a single-step move, exactly as the desktop's move handlers do.
  RuleEditorState _swap(int from, int to) {
    if (from < 0 || from >= rules.length) return this;
    if (to < 0 || to >= rules.length) return this;
    if (from == to) return this;

    final next = List<ClashRule>.of(rules);
    final moved = next[from];
    next[from] = next[to];
    next[to] = moved;

    // `next[to]` is the row that just moved. A prepend counts from the top, so
    // moving up lowers its offset; an append counts from the bottom, so moving
    // up raises it.
    final movingUp = to < from;
    if (prepend.contains(from)) {
      next[to] = _shiftOffset(next[to], movingUp ? -1 : 1);
    }
    if (append.contains(from)) {
      next[to] = _shiftOffset(next[to], movingUp ? 1 : -1);
    }

    return RuleEditorState(
      rules: next,
      prepend: _swapped(prepend, from, to),
      append: _swapped(append, from, to),
      deleted: _swapped(deleted, from, to),
    );
  }

  /// Turns the three index sets back into an overlay document.
  ///
  /// A row that is both added and deleted contributes nothing — it was staged
  /// and then withdrawn. A deleted row that the profile itself owns becomes a
  /// `delete:` entry, written without an offset so it matches the profile's own
  /// rule string verbatim.
  RuleOverlay toOverlay() {
    final prependStrings = <String>[
      for (final index in _sorted(prepend))
        if (!deleted.contains(index) && index < rules.length)
          rules[index].format(),
    ];
    final appendStrings = <String>[
      for (final index in _sorted(append))
        if (!deleted.contains(index) && index < rules.length)
          rules[index].format(),
    ];
    final deleteStrings = <String>[
      for (final index in _sorted(deleted))
        if (index < rules.length &&
            !prepend.contains(index) &&
            !append.contains(index))
          rules[index].formatWithoutOffset(),
    ];

    return RuleOverlay(
      prepend: prependStrings,
      append: appendStrings,
      delete: deleteStrings,
    );
  }
}

// ---------------------------------------------------------------------------

List<int> _sorted(Set<int> values) => values.toList(growable: false)..sort();

/// Moves a rule's overlay offset by [delta].
///
/// Zero and "no offset" mean the same thing — the top for a prepend, the bottom
/// for an append — so the offset is dropped rather than written as `0,`, which
/// `ClashRule.parse` would discard on the way back in anyway. Keeping the model
/// canonical is what makes an editor round trip comparable.
ClashRule _shiftOffset(ClashRule rule, int delta) {
  final next = (rule.offset ?? 0) + delta;
  return next <= 0
      ? rule.copyWith(clearOffset: true)
      : rule.copyWith(offset: next);
}

Set<int> _shifted(Set<int> values, int insertPosition) => <int>{
  for (final value in values) value >= insertPosition ? value + 1 : value,
};

Set<int> _swapped(Set<int> values, int a, int b) => <int>{
  for (final value in values)
    if (value == a) b else if (value == b) a else value,
};

void _shiftAllBy(Set<int> target, List<int> insertions) {
  final shifted = <int>{};
  for (final value in target) {
    var moved = value;
    for (final position in insertions) {
      if (moved >= position) moved++;
    }
    shifted.add(moved);
  }
  target
    ..clear()
    ..addAll(shifted);
}

/// Splices every rule in [additions] into [rules], keeping track of where each
/// one landed while earlier insertions shift the later indices.
({List<ClashRule> rules, Set<int> indices, List<int> insertions}) _spliceAll(
  List<ClashRule> rules,
  List<ClashRule> additions,
  int Function(ClashRule rule, List<ClashRule> current) positionOf,
) {
  final result = List<ClashRule>.of(rules);
  final indices = <int>{};
  final insertions = <int>[];

  for (final rule in additions) {
    final position = positionOf(rule, result).clamp(0, result.length);
    result.insert(position, rule);
    insertions.add(position);
    final shifted = <int>{
      for (final index in indices) index >= position ? index + 1 : index,
      position,
    };
    indices
      ..clear()
      ..addAll(shifted);
  }

  return (rules: result, indices: indices, insertions: insertions);
}
