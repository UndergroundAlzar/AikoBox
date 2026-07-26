import 'package:aikobox_mobile/widgets/common_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

ShapeDecoration _decorationOf(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(CommonCard),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return container.decoration! as ShapeDecoration;
}

BorderSide _borderOf(WidgetTester tester) =>
    (_decorationOf(tester).shape as RoundedRectangleBorder).side;

void main() {
  group('CommonCard', () {
    testWidgets('renders its child with no header when none is given', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(const CommonCard(child: Text('body')), width: 300),
      );

      expect(find.text('body'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders the header icon at 18 px tinted primary', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          const CommonCard(
            icon: Icons.speed_sharp,
            label: 'Network speed',
            child: Text('body'),
          ),
          width: 300,
        ),
      );

      expect(find.text('Network speed'), findsOneWidget);

      final icon = tester.widget<Icon>(find.byIcon(Icons.speed_sharp));
      expect(icon.size, 18);
      expect(icon.color, hostScheme(Brightness.light).primary);
    });

    testWidgets('draws a transparent fill and a 1 px outlineVariant hairline', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(const CommonCard(child: Text('body')), width: 300),
      );

      final decoration = _decorationOf(tester);
      final side = _borderOf(tester);

      expect(decoration.color, Colors.transparent);
      expect(side.width, 1);
      expect(side.color, hostScheme(Brightness.light).outlineVariant);
      expect(decoration.shadows, isNull);
    });

    testWidgets('selection changes colour but never the border width', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          const CommonCard(isSelected: true, child: Text('body')),
          width: 300,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final scheme = hostScheme(Brightness.light);
      expect(_decorationOf(tester).color, scheme.primaryContainer);
      expect(_borderOf(tester).color, scheme.primary);
      // A thicker selected border would shift the content box and reflow the
      // card; the design pins it at 1 px.
      expect(_borderOf(tester).width, 1);
    });

    testWidgets('isError paints the hairline in the error colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          const CommonCard(isError: true, child: Text('body')),
          width: 300,
        ),
      );

      expect(_borderOf(tester).color, hostScheme(Brightness.light).error);
    });

    testWidgets('uses the dark scheme hairline in dark mode', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          const CommonCard(child: Text('body')),
          width: 300,
          brightness: Brightness.dark,
        ),
      );

      final darkScheme = hostScheme(Brightness.dark);
      expect(_borderOf(tester).color, darkScheme.outlineVariant);
      // The dark hairline must not be the light one — the two schemes are tuned
      // independently.
      expect(
        darkScheme.outlineVariant,
        isNot(hostScheme(Brightness.light).outlineVariant),
      );
    });

    testWidgets('fires onTap and onLongPress', (tester) async {
      var taps = 0;
      var longPresses = 0;

      await tester.pumpWidget(
        hostWidget(
          CommonCard(
            onTap: () => taps++,
            onLongPress: () => longPresses++,
            child: const Text('body'),
          ),
          width: 300,
        ),
      );

      await tester.tap(find.text('body'));
      await tester.pump();
      expect(taps, 1);

      await tester.longPress(find.text('body'));
      await tester.pump();
      expect(longPresses, 1);
    });

    testWidgets('is not interactive without callbacks', (tester) async {
      await tester.pumpWidget(
        hostWidget(const CommonCard(child: Text('body')), width: 300),
      );

      expect(
        find.descendant(
          of: find.byType(CommonCard),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    });

    testWidgets('stacks the selected overlay only while selected', (
      tester,
    ) async {
      const overlay = Icon(Icons.check_rounded, key: ValueKey('check'));

      await tester.pumpWidget(
        hostWidget(
          const CommonCard(selectedOverlay: overlay, child: Text('body')),
          width: 300,
        ),
      );
      expect(find.byKey(const ValueKey('check')), findsNothing);

      await tester.pumpWidget(
        hostWidget(
          const CommonCard(
            isSelected: true,
            selectedOverlay: overlay,
            child: Text('body'),
          ),
          width: 300,
        ),
      );
      expect(find.byKey(const ValueKey('check')), findsOneWidget);
    });

    testWidgets('header actions are rendered after the label', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          CommonCard(
            icon: Icons.dns_rounded,
            label: 'DNS',
            headerActions: <Widget>[
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
            child: const Text('body'),
          ),
          width: 300,
        ),
      );

      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      final labelX = tester.getCenter(find.text('DNS')).dx;
      final actionX = tester.getCenter(find.byIcon(Icons.refresh_rounded)).dx;
      expect(actionX, greaterThan(labelX));
    });
  });
}
