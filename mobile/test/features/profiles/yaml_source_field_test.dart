import 'package:aikobox_mobile/features/profiles/widgets/yaml_source_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Future<TextEditingController> pumpField(
    WidgetTester tester,
    String text, {
    int? errorLine,
    bool readOnly = false,
  }) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    await pumpPage(
      tester,
      Scaffold(
        body: SizedBox(
          height: 400,
          child: YamlSourceField(
            controller: controller,
            errorLine: errorLine,
            readOnly: readOnly,
          ),
        ),
      ),
      container: container,
    );
    return controller;
  }

  /// The gutter renders each line number as its own `Text`.
  Finder gutterNumber(String value) => find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == value,
  );

  testWidgets('numbers every line', (tester) async {
    await pumpField(tester, 'a: 1\nb: 2\nc: 3\n');

    // Three content lines plus the empty line after the trailing newline.
    expect(gutterNumber('1'), findsOneWidget);
    expect(gutterNumber('2'), findsOneWidget);
    expect(gutterNumber('3'), findsOneWidget);
    expect(gutterNumber('4'), findsOneWidget);
    expect(gutterNumber('5'), findsNothing);
  });

  testWidgets('an empty document still has line 1', (tester) async {
    await pumpField(tester, '');
    expect(gutterNumber('1'), findsOneWidget);
    expect(gutterNumber('2'), findsNothing);
  });

  testWidgets('the gutter follows the text as it is edited', (tester) async {
    final controller = await pumpField(tester, 'a: 1\n');
    expect(gutterNumber('2'), findsOneWidget);
    expect(gutterNumber('3'), findsNothing);

    controller.text = 'a: 1\nb: 2\nc: 3';
    await tester.pumpAndSettle();
    expect(gutterNumber('3'), findsOneWidget);
    expect(gutterNumber('4'), findsNothing);
  });

  testWidgets('the failing line is highlighted', (tester) async {
    await pumpField(tester, 'a: 1\nb: [\nc: 3\n', errorLine: 2);

    final scheme = Theme.of(
      tester.element(find.byType(YamlSourceField)),
    ).colorScheme;

    Color? colourOf(String line) {
      final container = tester.widget<Container>(
        find.ancestor(of: gutterNumber(line), matching: find.byType(Container)),
      );
      return container.color;
    }

    expect(colourOf('2'), scheme.errorContainer);
    expect(colourOf('1'), Colors.transparent);
  });

  testWidgets('the field is editable and reports its text', (tester) async {
    final controller = await pumpField(tester, 'a: 1');
    await tester.enterText(find.byType(TextField), 'a: 2');
    await tester.pumpAndSettle();
    expect(controller.text, 'a: 2');
  });

  testWidgets('read-only refuses edits', (tester) async {
    final controller = await pumpField(tester, 'a: 1', readOnly: true);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
    expect(controller.text, 'a: 1');
  });

  testWidgets('autocorrect is off — it would rewrite config keys', (
    tester,
  ) async {
    await pumpField(tester, 'dns:\n  enable: true\n');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.maxLines, isNull);
  });

  testWidgets('a long line scrolls horizontally instead of wrapping', (
    tester,
  ) async {
    await pumpField(tester, 'a: ${'x' * 400}\n');

    // One logical line stays one gutter row; if the text wrapped, the gutter
    // and the text would drift apart on every following line.
    expect(gutterNumber('1'), findsOneWidget);
    expect(gutterNumber('2'), findsOneWidget);
    expect(gutterNumber('3'), findsNothing);

    final horizontal = tester.widgetList<Scrollable>(find.byType(Scrollable));
    expect(
      horizontal.any((s) => s.axisDirection == AxisDirection.right),
      isTrue,
    );
  });
}
