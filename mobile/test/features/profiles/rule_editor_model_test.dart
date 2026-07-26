import 'package:aikobox_mobile/features/profiles/data/rule_editor_model.dart';
import 'package:aikobox_mobile/features/profiles/data/rule_overlay.dart';
import 'package:aikobox_mobile/features/profiles/data/rule_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

const List<String> _baseStrings = <String>[
  'DOMAIN,a.com,DIRECT',
  'GEOIP,CN,DIRECT',
  'MATCH,PROXY',
];

List<ClashRule> _base() =>
    _baseStrings.map(ClashRule.parse).toList(growable: false);

/// The rules as the editor shows them — no offset prefixes, because the offset
/// is drawn as a separate chip and is not part of the rule.
List<String> _displayed(RuleEditorState state) => state.rules
    .map((rule) => rule.formatWithoutOffset())
    .toList(growable: false);

/// What the core would end up reading, given the base and the saved overlay.
List<String> _materialised(RuleEditorState state) =>
    applyRuleOverlay(_baseStrings, state.toOverlay());

void main() {
  group('load', () {
    test('with no overlay the list is the profile itself', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty);
      expect(_displayed(state), _baseStrings);
      expect(state.hasChanges, isFalse);
      expect(
        state.rows().map((row) => row.state),
        everyElement(RuleRowState.original),
      );
    });

    test('prepends land at the top and are marked as added', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
      );
      expect(_displayed(state).first, 'DOMAIN,x.com,PROXY');
      expect(state.stateOf(0), RuleRowState.added);
      expect(state.stateOf(1), RuleRowState.original);
    });

    test('appends land at the bottom and are marked as added', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(append: <String>['MATCH,DIRECT']),
      );
      expect(_displayed(state).last, 'MATCH,DIRECT');
      expect(state.stateOf(state.length - 1), RuleRowState.added);
    });

    test('an offset prepend lands at that index', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(prepend: <String>['2,DOMAIN,x.com,PROXY']),
      );
      expect(state.stateOf(2), RuleRowState.added);
      expect(state.rules[2].payload, 'x.com');
    });

    test('an offset append counts back from the end', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(append: <String>['1,DOMAIN,x.com,PROXY']),
      );
      expect(state.stateOf(2), RuleRowState.added);
      expect(state.rules[2].payload, 'x.com');
      expect(state.rules[3].isMatch, isTrue);
    });

    test('deletes strike out the matching row', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(delete: <String>['GEOIP,CN,DIRECT']),
      );
      expect(state.stateOf(1), RuleRowState.deleted);
      expect(state.rows()[1].isDeleted, isTrue);
    });

    test('a delete that matches nothing is ignored', () {
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(delete: <String>['GEOIP,US,DIRECT']),
      );
      expect(state.deleted, isEmpty);
    });

    test('an offset append does not mislabel a prepend row', () {
      // The desktop forgets to shift the prepend indices when an offset append
      // splices in above them; this port does not.
      final state = RuleEditorState.load(
        _base(),
        const RuleOverlay(
          prepend: <String>['DOMAIN,top.com,PROXY'],
          append: <String>['4,DOMAIN,mid.com,PROXY'],
        ),
      );
      final top = state.rows().firstWhere(
        (row) => row.rule.payload == 'top.com',
      );
      final mid = state.rows().firstWhere(
        (row) => row.rule.payload == 'mid.com',
      );
      expect(state.prepend, contains(top.index));
      expect(state.append, contains(mid.index));
      expect(state.prepend, isNot(contains(mid.index)));
    });
  });

  group('editing', () {
    test('inserting a prepend puts it on top and records it', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: true,
      );

      expect(_displayed(state).first, 'DOMAIN,x.com,PROXY');
      expect(state.prepend, <int>{0});
      expect(state.toOverlay().prepend, <String>['DOMAIN,x.com,PROXY']);
      expect(_materialised(state), _displayed(state));
    });

    test('two prepends keep the order they were added in', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty);
      state = state.insert(
        const ClashRule(type: 'DOMAIN', payload: 'first.com', proxy: 'PROXY'),
        asPrepend: true,
      );
      state = state.insert(
        const ClashRule(type: 'DOMAIN', payload: 'second.com', proxy: 'PROXY'),
        asPrepend: true,
      );

      // Newest on top, as on the desktop; the overlay lists them in the same
      // order the list shows them.
      expect(state.toOverlay().prepend, <String>[
        'DOMAIN,second.com,PROXY',
        'DOMAIN,first.com,PROXY',
      ]);
      expect(_materialised(state), _displayed(state));
    });

    test('inserting an append puts it at the bottom', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'MATCH', proxy: 'DIRECT'),
        asPrepend: false,
      );
      expect(_displayed(state).last, 'MATCH,DIRECT');
      expect(state.toOverlay().append, <String>['MATCH,DIRECT']);
      expect(_materialised(state), _displayed(state));
    });

    test('an insertion shifts the indices already recorded', () {
      var state = RuleEditorState.load(
        _base(),
        const RuleOverlay(delete: <String>['MATCH,PROXY']),
      );
      expect(state.deleted, <int>{2});

      state = state.insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: true,
      );
      expect(state.deleted, <int>{3});
      expect(state.rules[3].isMatch, isTrue);
    });

    test('toggleDelete marks and then unmarks', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty);
      state = state.toggleDelete(1);
      expect(state.stateOf(1), RuleRowState.deleted);
      expect(state.toOverlay().delete, <String>['GEOIP,CN,DIRECT']);

      state = state.toggleDelete(1);
      expect(state.stateOf(1), RuleRowState.original);
      expect(state.toOverlay().delete, isEmpty);
    });

    test('a staged row that is then deleted contributes nothing', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: true,
      );
      state = state.toggleDelete(0);

      final overlay = state.toOverlay();
      expect(overlay.prepend, isEmpty);
      expect(overlay.delete, isEmpty);
      expect(applyRuleOverlay(_baseStrings, overlay), _baseStrings);
    });

    test('a delete entry is written without its offset', () {
      // A row that came from an offset prepend and is then withdrawn must not
      // leave a `delete` entry carrying "3," — the profile's own rule string
      // never has one, so it would never match.
      final loaded = RuleEditorState.load(
        _base(),
        const RuleOverlay(prepend: <String>['1,DOMAIN,x.com,PROXY']),
      );
      final state = loaded.toggleDelete(1);
      expect(state.toOverlay().prepend, isEmpty);
      expect(state.toOverlay().delete, isEmpty);
    });
  });

  group('moving', () {
    test('moving a plain row up swaps it', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty).moveUp(1);
      expect(_displayed(state), <String>[
        'GEOIP,CN,DIRECT',
        'DOMAIN,a.com,DIRECT',
        'MATCH,PROXY',
      ]);
    });

    test('moving out of bounds is a no-op', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty);
      expect(_displayed(state.moveUp(0)), _baseStrings);
      expect(_displayed(state.moveDown(state.length - 1)), _baseStrings);
      expect(_displayed(state.moveUp(-1)), _baseStrings);
    });

    test('moving a prepended row down gives it an offset that round-trips', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: true,
      );
      state = state.moveDown(0);

      expect(state.rules[1].payload, 'x.com');
      expect(state.rules[1].offset, 1);
      expect(state.prepend, <int>{1});
      expect(state.toOverlay().prepend, <String>['1,DOMAIN,x.com,PROXY']);
      // The saved overlay reproduces exactly what the editor is showing.
      expect(_materialised(state), _displayed(state));

      // And re-opening the editor on that overlay reproduces the same state,
      // offset included.
      final reloaded = RuleEditorState.load(_base(), state.toOverlay());
      expect(_displayed(reloaded), _displayed(state));
      expect(reloaded.prepend, state.prepend);
      expect(reloaded.rules[1].offset, 1);
    });

    test('moving a prepended row back up clears the offset', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: true,
      );
      state = state.moveDown(0).moveUp(1);
      expect(state.rules[0].payload, 'x.com');
      expect(state.rules[0].offset, isNull);
      expect(state.toOverlay().prepend, <String>['DOMAIN,x.com,PROXY']);
      expect(_materialised(state), _displayed(state));
    });

    test('moving an appended row up gives it an offset that round-trips', () {
      var state = RuleEditorState.load(_base(), RuleOverlay.empty).insert(
        const ClashRule(type: 'DOMAIN', payload: 'x.com', proxy: 'PROXY'),
        asPrepend: false,
      );
      state = state.moveUp(state.length - 1);

      expect(state.rules[2].payload, 'x.com');
      expect(state.rules[2].offset, 1);
      expect(state.toOverlay().append, <String>['1,DOMAIN,x.com,PROXY']);
      expect(_materialised(state), _displayed(state));

      final reloaded = RuleEditorState.load(_base(), state.toOverlay());
      expect(_displayed(reloaded), _displayed(state));
      expect(reloaded.append, state.append);
    });

    test('a move keeps the delete marker on the row that moved', () {
      var state = RuleEditorState.load(
        _base(),
        const RuleOverlay(delete: <String>['GEOIP,CN,DIRECT']),
      );
      state = state.moveUp(1);
      expect(state.rules[0].payload, 'CN');
      expect(state.deleted, <int>{0});
      expect(state.toOverlay().delete, <String>['GEOIP,CN,DIRECT']);
    });
  });

  group('search', () {
    test('matches type, payload, outbound and parameters', () {
      final state = RuleEditorState.load(<ClashRule>[
        ClashRule.parse('DOMAIN,a.com,DIRECT'),
        ClashRule.parse('GEOIP,CN,PROXY,no-resolve'),
      ], RuleOverlay.empty);
      expect(state.search('geoip').length, 1);
      expect(state.search('a.com').length, 1);
      expect(state.search('PROXY').length, 1);
      expect(state.search('no-resolve').length, 1);
      expect(state.search('').length, 2);
      expect(state.search('nothing'), isEmpty);
    });

    test('a matched row keeps its real index so actions hit the right row', () {
      final state = RuleEditorState.load(_base(), RuleOverlay.empty);
      final rows = state.search('MATCH');
      expect(rows, hasLength(1));
      expect(rows.single.index, 2);
    });
  });

  test('the state is immutable', () {
    final state = RuleEditorState.load(_base(), RuleOverlay.empty);
    expect(
      () => state.rules.add(const ClashRule(type: 'X')),
      throwsUnsupportedError,
    );
    expect(() => state.deleted.add(0), throwsUnsupportedError);
  });
}
