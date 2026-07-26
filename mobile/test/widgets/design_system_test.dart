import 'package:aikobox_mobile/theme/theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('AikoTheme', () {
    test('light and dark are tuned independently', () {
      final light = AikoTheme.light().colorScheme;
      final dark = AikoTheme.dark().colorScheme;

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.outlineVariant, isNot(dark.outlineVariant));
      expect(light.surface, isNot(dark.surface));
    });

    test('the dark surface ladder stays monotonic after deepening', () {
      final s = AikoTheme.dark().colorScheme;
      final steps = <Color>[
        s.surfaceContainerLowest,
        s.surface,
        s.surfaceContainerLow,
        s.surfaceContainer,
        s.surfaceContainerHigh,
        s.surfaceContainerHighest,
      ];
      for (var i = 1; i < steps.length; i++) {
        expect(
          steps[i].computeLuminance(),
          greaterThan(steps[i - 1].computeLuminance()),
          reason: 'surface ladder step $i must be lighter than step ${i - 1}',
        );
      }
    });

    test('both themes register the status colour extension', () {
      for (final theme in <ThemeData>[AikoTheme.light(), AikoTheme.dark()]) {
        expect(theme.extension<AikoStatusColors>(), isNotNull);
      }
      expect(
        AikoTheme.light().extension<AikoStatusColors>()!.good,
        isNot(AikoTheme.dark().extension<AikoStatusColors>()!.good),
      );
    });

    test('a different seed produces a different palette', () {
      expect(
        AikoTheme.light(seedColor: kAikoSeedAzure.color).colorScheme.primary,
        isNot(AikoTheme.light(seedColor: kAikoSeedJade.color).colorScheme.primary),
      );
    });
  });

  group('seed palette', () {
    test('ids are unique', () {
      final ids = kAikoSeedColors.map((s) => s.id).toSet();
      expect(ids.length, kAikoSeedColors.length);
    });

    test('an unknown id resolves to the default rather than throwing', () {
      expect(aikoSeedColorById(null), kAikoDefaultSeedColor);
      expect(aikoSeedColorById('not-a-colour'), kAikoDefaultSeedColor);
      expect(aikoSeedColorById(kAikoSeedJade.id), kAikoSeedJade);
    });
  });

  group('delayLevelFor', () {
    test('classifies by the 600 ms ceiling and treats <= 0 as failure', () {
      expect(delayLevelFor(null), DelayLevel.unknown);
      expect(delayLevelFor(0), DelayLevel.bad);
      expect(delayLevelFor(-1), DelayLevel.bad);
      expect(delayLevelFor(1), DelayLevel.good);
      expect(delayLevelFor(599), DelayLevel.good);
      expect(delayLevelFor(600), DelayLevel.warn);
      expect(delayLevelFor(5000), DelayLevel.warn);
    });
  });

  group('DelayChip', () {
    ShapeDecoration decorationOf(WidgetTester tester) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byType(DelayChip),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration;

    testWidgets('shows the value for a healthy reading', (tester) async {
      await tester.pumpWidget(hostWidget(const DelayChip(delay: 120)));
      expect(find.text('120 ms'), findsOneWidget);
      expect(
        decorationOf(tester).color,
        AikoStatusColors.forBrightness(Brightness.light).goodContainer,
      );
    });

    testWidgets('switches to the warn container past the ceiling', (
      tester,
    ) async {
      await tester.pumpWidget(hostWidget(const DelayChip(delay: 900)));
      expect(find.text('900 ms'), findsOneWidget);
      expect(
        decorationOf(tester).color,
        AikoStatusColors.forBrightness(Brightness.light).warnContainer,
      );
    });

    testWidgets('renders failure as a glyph, not a word', (tester) async {
      await tester.pumpWidget(hostWidget(const DelayChip(delay: 0)));
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('shows a spinner while testing', (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(hostWidget(const DelayChip(testing: true)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('uses the dark status palette in dark mode', (tester) async {
      await tester.pumpWidget(
        hostWidget(const DelayChip(delay: 120), brightness: Brightness.dark),
      );
      expect(
        decorationOf(tester).color,
        AikoStatusColors.forBrightness(Brightness.dark).goodContainer,
      );
    });
  });

  group('Sparkline', () {
    testWidgets('paints a single series and survives a value swap', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(
          SizedBox(
            width: 200,
            height: 60,
            child: Sparkline.single(
              values: const <double>[0, 4, 2, 9, 3, 7],
            ),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        hostWidget(
          SizedBox(
            width: 200,
            height: 60,
            child: Sparkline.single(
              values: const <double>[4, 2, 9, 3, 7, 1],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles all-zero and single-point windows', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          const SizedBox(
            width: 200,
            height: 60,
            child: Sparkline(
              series: <SparklineSeries>[
                SparklineSeries(values: <double>[0, 0, 0, 0]),
                SparklineSeries(values: <double>[5]),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders two series in dark mode', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          const SizedBox(
            width: 200,
            height: 60,
            child: Sparkline(
              series: <SparklineSeries>[
                SparklineSeries(values: <double>[1, 5, 3], color: Colors.teal),
                SparklineSeries(values: <double>[4, 1, 6], fill: false),
              ],
            ),
          ),
          brightness: Brightness.dark,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SectionList', () {
    Widget buildList() => const SectionList(
      sections: <SectionListSection>[
        SectionListSection(
          title: 'More',
          tiles: <SectionListTile>[
            SectionListTile(title: 'Connections', icon: Icons.ballot),
            SectionListTile(title: 'Logs', icon: Icons.adb),
          ],
        ),
        SectionListSection(
          title: 'Settings',
          tiles: <SectionListTile>[
            SectionListTile(
              title: 'Theme',
              subtitle: 'Colours and dark mode',
              icon: Icons.style,
            ),
            SectionListTile(
              title: 'Reset',
              icon: Icons.delete_forever,
              destructive: true,
            ),
          ],
        ),
      ],
    );

    testWidgets('tints section headers with primary', (tester) async {
      await tester.pumpWidget(
        hostWidget(SizedBox(height: 500, child: buildList()), width: 400),
      );

      final header = tester.widget<Text>(find.text('More'));
      expect(header.style?.color, hostScheme(Brightness.light).primary);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('renders one divider between the rows of each section', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(SizedBox(height: 500, child: buildList()), width: 400),
      );

      // Two sections of two rows each: one divider inside each section.
      expect(find.byType(Divider), findsNWidgets(2));
    });

    testWidgets('destructive rows are painted in the error colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostWidget(SizedBox(height: 500, child: buildList()), width: 400),
      );

      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Reset'), matching: find.byType(ListTile)),
      );
      expect(tile.titleTextStyle?.color, hostScheme(Brightness.light).error);
      expect(tile.iconColor, hostScheme(Brightness.light).error);
    });

    testWidgets('renders in dark mode', (tester) async {
      await tester.pumpWidget(
        hostWidget(
          SizedBox(height: 500, child: buildList()),
          width: 400,
          brightness: Brightness.dark,
        ),
      );

      final header = tester.widget<Text>(find.text('More'));
      expect(header.style?.color, hostScheme(Brightness.dark).primary);
    });
  });

  group('AikoScaffold', () {
    testWidgets('has a flat transparent app bar and a plain title', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AikoTheme.light(),
          home: const AikoScaffold(
            title: 'Dashboard',
            body: Text('content'),
          ),
        ),
      );

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, Colors.transparent);
      expect(appBar.elevation, 0);
      expect(appBar.scrolledUnderElevation, 0);
      expect(appBar.centerTitle, isFalse);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('renders in dark mode with a FAB', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AikoTheme.dark(),
          home: AikoScaffold(
            title: 'Proxies',
            body: const Text('content'),
            floatingActionButton: AikoFab(running: false, onPressed: () {}),
          ),
        ),
      );

      expect(find.byType(AikoFab), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('EmptyState', () {
    testWidgets('renders title, message and action in both brightnesses', (
      tester,
    ) async {
      for (final brightness in <Brightness>[
        Brightness.light,
        Brightness.dark,
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          hostWidget(
            EmptyState(
              icon: Icons.folder_off_outlined,
              title: 'No profiles',
              message: 'Import a subscription to get started.',
              action: FilledButton.tonal(
                onPressed: () {},
                child: const Text('Import'),
              ),
            ),
            brightness: brightness,
            width: 360,
          ),
        );

        expect(find.text('No profiles'), findsOneWidget);
        expect(
          find.text('Import a subscription to get started.'),
          findsOneWidget,
        );
        expect(find.text('Import'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('showAikoConfirmSheet', () {
    Future<bool?> runSheet(WidgetTester tester, String tapLabel) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AikoTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showAikoConfirmSheet(
                      context,
                      title: 'Delete profile?',
                      message: 'This cannot be undone.',
                      confirmLabel: 'Delete',
                      cancelLabel: 'Cancel',
                      icon: Icons.delete_outline,
                      destructive: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Delete profile?'), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);

      await tester.tap(find.text(tapLabel));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('returns true only when confirmed', (tester) async {
      expect(await runSheet(tester, 'Delete'), isTrue);
    });

    testWidgets('returns false when cancelled', (tester) async {
      expect(await runSheet(tester, 'Cancel'), isFalse);
    });
  });
}
