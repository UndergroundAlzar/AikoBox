import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/aiko_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final Finder _fabContainer = find.descendant(
  of: find.byType(AikoFab),
  matching: find.byType(AnimatedContainer),
);

Size _fabSize(WidgetTester tester) => tester.getSize(_fabContainer);

ShapeDecoration _fabDecoration(WidgetTester tester) =>
    tester.widget<AnimatedContainer>(_fabContainer).decoration!
        as ShapeDecoration;

void main() {
  group('AikoFab.formatElapsed', () {
    test('pads to HH:MM:SS', () {
      expect(AikoFab.formatElapsed(Duration.zero), '00:00:00');
      expect(AikoFab.formatElapsed(const Duration(seconds: 7)), '00:00:07');
      expect(
        AikoFab.formatElapsed(const Duration(minutes: 3, seconds: 9)),
        '00:03:09',
      );
      expect(
        AikoFab.formatElapsed(
          const Duration(hours: 2, minutes: 30, seconds: 1),
        ),
        '02:30:01',
      );
    });

    test('runs past 24 hours instead of wrapping', () {
      expect(AikoFab.formatElapsed(const Duration(hours: 30)), '30:00:00');
    });

    test('clamps a negative duration to zero', () {
      expect(AikoFab.formatElapsed(const Duration(seconds: -5)), '00:00:00');
    });
  });

  group('AikoFab', () {
    testWidgets('is a 56 px rocket button while stopped', (tester) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: false, onPressed: () {})),
      );

      expect(find.byIcon(Icons.rocket_launch_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      expect(_fabSize(tester), const Size(AikoDims.fabSize, AikoDims.fabSize));
      // The clock is always laid out at the pill's full width — the 56 px
      // container clips it. That is what lets the two states be one container.
      expect(find.text('00:00:00'), findsOneWidget);
    });

    testWidgets('widens into a pause + clock pill while running', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: true, onPressed: () {})),
      );

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_rounded), findsNothing);
      expect(find.text('00:00:00'), findsOneWidget);

      final size = _fabSize(tester);
      expect(size.height, AikoDims.fabSize);
      expect(size.width, greaterThan(AikoDims.fabSize));
    });

    testWidgets('morphs width continuously rather than swapping widgets', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: false, onPressed: () {})),
      );
      final collapsed = _fabSize(tester).width;

      await tester.pumpWidget(
        hostWidget(AikoFab(running: true, onPressed: () {})),
      );
      // One AnimatedContainer throughout — the same render object is resized.
      expect(
        find.descendant(
          of: find.byType(AikoFab),
          matching: find.byType(AnimatedContainer),
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 100));
      final midway = _fabSize(tester).width;
      expect(midway, greaterThan(collapsed));

      await tester.pump(const Duration(milliseconds: 400));
      final expanded = _fabSize(tester).width;
      expect(expanded, greaterThan(midway));
    });

    testWidgets('derives the clock from startedAt', (tester) async {
      final started = DateTime.now().subtract(
        const Duration(minutes: 1, seconds: 5),
      );

      await tester.pumpWidget(
        hostWidget(
          AikoFab(running: true, startedAt: started, onPressed: () {}),
        ),
      );

      expect(find.text('00:01:05'), findsOneWidget);

      // Let the one-second ticker fire, then tear the tree down so the timer is
      // cancelled and the test does not leak it.
      await tester.pump(const Duration(milliseconds: 1100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('runs no ticker when there is no start time', (tester) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: true, onPressed: () {})),
      );

      // Nothing pending: pumpAndSettle would hang on a live periodic timer.
      await tester.pumpAndSettle();
      expect(find.text('00:00:00'), findsOneWidget);
    });

    testWidgets('invokes onPressed', (tester) async {
      var presses = 0;
      await tester.pumpWidget(
        hostWidget(AikoFab(running: false, onPressed: () => presses++)),
      );

      await tester.tap(find.byType(AikoFab));
      await tester.pump();
      expect(presses, 1);
    });

    testWidgets('is inert when onPressed is null', (tester) async {
      await tester.pumpWidget(hostWidget(const AikoFab(running: false)));

      final inkWell = tester.widget<InkWell>(
        find.descendant(
          of: find.byType(AikoFab),
          matching: find.byType(InkWell),
        ),
      );
      expect(inkWell.onTap, isNull);

      await tester.tap(find.byType(AikoFab));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a spinner instead of a glyph while busy', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: false, busy: true, onPressed: () {})),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_rounded), findsNothing);
    });

    testWidgets('is filled with primaryContainer and lifted in light mode', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(AikoFab(running: false, onPressed: () {})),
      );

      final decoration = _fabDecoration(tester);
      expect(decoration.color, hostScheme(Brightness.light).primaryContainer);
      expect(decoration.shadows, isNotNull);
    });

    testWidgets('is filled with primaryContainer and flat in dark mode', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          AikoFab(running: false, onPressed: () {}),
          brightness: Brightness.dark,
        ),
      );

      final decoration = _fabDecoration(tester);
      expect(decoration.color, hostScheme(Brightness.dark).primaryContainer);
      // A dark surface already separates the FAB; a drop shadow only muddies it.
      expect(decoration.shadows, isNull);
    });
  });
}
