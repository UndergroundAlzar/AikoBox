import 'package:aikobox_mobile/widgets/staggered_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

StaggeredGridItem _cell(String id, {int span = 1, bool visible = true}) {
  return StaggeredGridItem(
    columnSpan: span,
    visible: visible,
    child: Container(key: ValueKey<String>(id), height: 40),
  );
}

void main() {
  group('StaggeredGrid.columnsForWidth', () {
    test('never drops below two columns', () {
      expect(StaggeredGrid.columnsForWidth(320), 2);
      expect(StaggeredGrid.columnsForWidth(0), 2);
      expect(StaggeredGrid.columnsForWidth(639), 2);
    });

    test('adds columns at the layout breakpoints', () {
      expect(StaggeredGrid.columnsForWidth(640), 3);
      expect(StaggeredGrid.columnsForWidth(880), 4);
      expect(StaggeredGrid.columnsForWidth(1120), 5);
    });
  });

  group('StaggeredGrid layout', () {
    testWidgets(
      'a 1-span cell is one column wide, a 2-span cell fills the row',
      (tester) async {
        await tester.pumpWidget(
          hostWidget(
            StaggeredGrid(
              crossAxisCount: 2,
              spacing: 12,
              items: <StaggeredGridItem>[_cell('a'), _cell('b', span: 2)],
            ),
            width: 600,
          ),
        );

        // cell = (600 - 1 * 12) / 2 = 294
        expect(tester.getSize(find.byKey(const ValueKey('a'))).width, 294);
        // 2 spans re-absorb the gutter they straddle: 294 * 2 + 12 = 600
        expect(tester.getSize(find.byKey(const ValueKey('b'))).width, 600);
      },
    );

    testWidgets('cells wrap when the running span exceeds the column count', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 2,
            spacing: 12,
            items: <StaggeredGridItem>[_cell('a'), _cell('b'), _cell('c')],
          ),
          width: 600,
        ),
      );

      final a = tester.getTopLeft(find.byKey(const ValueKey('a')));
      final b = tester.getTopLeft(find.byKey(const ValueKey('b')));
      final c = tester.getTopLeft(find.byKey(const ValueKey('c')));

      expect(b.dy, a.dy, reason: 'a and b share the first row');
      expect(b.dx, greaterThan(a.dx));
      expect(c.dy, greaterThan(a.dy), reason: 'c wraps onto a second row');
      expect(c.dx, a.dx, reason: 'c starts a fresh row at the left edge');
    });

    testWidgets('a 2-span cell starts a new row rather than splitting', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 2,
            spacing: 12,
            items: <StaggeredGridItem>[_cell('a'), _cell('wide', span: 2)],
          ),
          width: 600,
        ),
      );

      final a = tester.getTopLeft(find.byKey(const ValueKey('a')));
      final wide = tester.getTopLeft(find.byKey(const ValueKey('wide')));
      expect(wide.dy, greaterThan(a.dy));
      expect(wide.dx, a.dx);
    });

    testWidgets('a span wider than the grid is clamped, not overflowed', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 1,
            spacing: 12,
            items: <StaggeredGridItem>[_cell('wide', span: 2)],
          ),
          width: 400,
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('wide'))).width, 400);
      expect(tester.takeException(), isNull);
    });

    testWidgets('invisible cells are removed from the layout entirely', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 2,
            spacing: 12,
            items: <StaggeredGridItem>[
              _cell('a'),
              _cell('hidden', visible: false),
              _cell('c'),
            ],
          ),
          width: 600,
        ),
      );

      expect(find.byKey(const ValueKey('hidden')), findsNothing);

      // With the hidden cell gone, a and c pair up on the first row.
      final a = tester.getTopLeft(find.byKey(const ValueKey('a')));
      final c = tester.getTopLeft(find.byKey(const ValueKey('c')));
      expect(c.dy, a.dy);
    });

    testWidgets('every cell in a row is stretched to the tallest one', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 2,
            spacing: 12,
            items: <StaggeredGridItem>[
              StaggeredGridItem(
                child: Container(key: const ValueKey<String>('short')),
              ),
              StaggeredGridItem(
                child: Container(
                  key: const ValueKey<String>('tall'),
                  height: 120,
                ),
              ),
            ],
          ),
          width: 600,
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('short'))).height, 120);
      expect(tester.getSize(find.byKey(const ValueKey('tall'))).height, 120);
    });

    testWidgets('rows are separated by the run spacing', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          StaggeredGrid(
            crossAxisCount: 1,
            spacing: 8,
            runSpacing: 20,
            items: <StaggeredGridItem>[_cell('a'), _cell('b')],
          ),
          width: 400,
        ),
      );

      final a = tester.getRect(find.byKey(const ValueKey('a')));
      final b = tester.getRect(find.byKey(const ValueKey('b')));
      expect(b.top - a.bottom, 20);
    });

    testWidgets('an empty item list renders nothing', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          const StaggeredGrid(items: <StaggeredGridItem>[]),
          width: 400,
        ),
      );

      expect(tester.getSize(find.byType(StaggeredGrid)).height, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
