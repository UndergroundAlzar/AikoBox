import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/settings/settings.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late Map<String, String> en;

  setUp(() {
    resetSettingsTestEnvironment();
    en = loadLocaleStrings();
  });

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(ThemeSettingsPage)),
        listen: false,
      );

  testWidgets('shows the preview, the three mode chips and every swatch', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    expect(find.text(en['theme.preview']!), findsOneWidget);
    expect(find.byType(ThemePreviewCard), findsOneWidget);

    for (final String key in <String>[
      'settings.backgroundAuto',
      'settings.backgroundLight',
      'settings.backgroundDark',
    ]) {
      expect(find.widgetWithText(ChoiceChip, en[key]!), findsOneWidget);
    }

    for (final AikoSeedColor seed in kAikoSeedColors) {
      expect(
        find.byKey(ValueKey<String>('seed-swatch-${seed.id}')),
        findsOneWidget,
        reason: seed.id,
      );
    }
  });

  testWidgets('picking a mode applies it and mirrors it into AppConfig', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    await tester.tap(
      find.widgetWithText(ChoiceChip, en['settings.backgroundDark']!),
    );
    await tester.pumpAndSettle();

    final ProviderContainer container = containerOf(tester);
    expect(container.read(themeControllerProvider).themeMode, ThemeMode.dark);
    expect(container.read(appConfigProvider).appTheme, AppThemeMode.dark);
  });

  testWidgets('picking a swatch persists the id and the mirrored ARGB', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    await tester.tap(find.byKey(const ValueKey<String>('seed-swatch-jade')));
    await tester.pumpAndSettle();

    final ProviderContainer container = containerOf(tester);
    expect(container.read(themeControllerProvider).seedColorId, 'jade');
    expect(
      container.read(appConfigProvider).seedColor,
      kAikoSeedJade.color.toARGB32(),
    );
  });

  testWidgets('the dynamic-colour switch persists both ways', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    final ProviderContainer container = containerOf(tester);
    expect(container.read(themeControllerProvider).useDynamicColor, isTrue);

    await tester.tap(find.byKey(const Key('theme-dynamic-switch')));
    await tester.pumpAndSettle();

    expect(container.read(themeControllerProvider).useDynamicColor, isFalse);
    expect(container.read(appConfigProvider).useDynamicColor, isFalse);
  });

  testWidgets('reset puts every appearance value back to its default', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    await tester.tap(
      find.widgetWithText(ChoiceChip, en['settings.backgroundLight']!),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('seed-swatch-violet')));
    await tester.pumpAndSettle();

    final ProviderContainer container = containerOf(tester);
    expect(container.read(themeControllerProvider).seedColorId, 'violet');

    await tester.tap(find.byKey(const Key('theme-reset')));
    await tester.pumpAndSettle();

    expect(
      container.read(themeControllerProvider),
      AikoThemeSettings.defaults,
    );
    expect(
      container.read(appConfigProvider).seedColor,
      kAikoDefaultSeedColorValue.toARGB32(),
    );
  });

  testWidgets('a config.json write failure does not undo a visible change', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ThemeSettingsPage(),
      overrides: settingsOverrides(failWrites: true),
      surface: const Size(420, 1200),
    );

    await tester.tap(
      find.widgetWithText(ChoiceChip, en['settings.backgroundDark']!),
    );
    await tester.pumpAndSettle();

    // shared_preferences is authoritative for the live theme; the mirror
    // failing must not roll back what the user can already see.
    expect(
      containerOf(tester).read(themeControllerProvider).themeMode,
      ThemeMode.dark,
    );
  });
}
