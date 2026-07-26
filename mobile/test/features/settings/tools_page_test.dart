import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/settings/settings.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late Map<String, String> en;

  setUp(() {
    resetSettingsTestEnvironment();
    en = loadLocaleStrings();
  });

  testWidgets('renders every section of the Tools list', (
    WidgetTester tester,
  ) async {
    // Tall enough that the lazy list builds every row in one pass.
    await pumpSettings(
      tester,
      const ToolsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1800),
    );

    for (final String key in <String>[
      'settings.section.appearance',
      'settings.section.network',
      'settings.section.core',
      'settings.section.general',
      'settings.section.android',
      'settings.section.backup',
      'settings.section.about',
    ]) {
      // `settings.section.about` and `about.title` are both "About" in en-US,
      // so this asserts presence rather than uniqueness.
      expect(find.text(en[key]!), findsAtLeastNWidgets(1), reason: key);
    }

    for (final Key key in <Key>[
      const Key('tools-theme'),
      const Key('tools-language'),
      const Key('tools-per-app'),
      const Key('tools-core'),
      const Key('tools-app'),
      const Key('tools-dashboard-cards'),
      const Key('tools-android'),
      const Key('tools-backup'),
      const Key('tools-about'),
    ]) {
      expect(find.byKey(key), findsOneWidget, reason: '$key');
    }
  });

  testWidgets('subtitles report the values currently in force', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ToolsPage(),
      overrides: settingsOverrides(
        config: AppConfig.defaults.copyWith(
          splitTunnelMode: SplitTunnelMode.deny,
          splitTunnelPackages: const <String>['a.b', 'c.d'],
        ),
      ),
    );

    // "All except selected apps · 2 apps"
    expect(find.textContaining(en['perApp.mode.denylist']!), findsOneWidget);
    expect(find.textContaining('2 apps'), findsOneWidget);
    // Theme mode defaults to "follow the system".
    expect(find.text(en['settings.backgroundAuto']!), findsOneWidget);
    expect(find.text(en['settings.language.system']!), findsOneWidget);
  });

  testWidgets('extraSections are spliced in before backup', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      ToolsPage(
        extraSections: <SectionListSection>[
          SectionListSection(
            title: 'Diagnostics',
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-extra-logs'),
                title: en['logs.title']!,
                icon: Icons.subject_rounded,
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
      overrides: settingsOverrides(),
    );

    expect(find.byKey(const Key('tools-extra-logs')), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
  });

  testWidgets('tapping Theme pushes the theme page', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ToolsPage(),
      overrides: settingsOverrides(),
    );

    await tester.tap(find.byKey(const Key('tools-theme')));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeSettingsPage), findsOneWidget);
    expect(find.text(en['theme.mode.title']!), findsOneWidget);
  });

  testWidgets('tapping About pushes the about page', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const ToolsPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1800),
    );

    await tester.tap(find.byKey(const Key('tools-about')));
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text(kAikoLicenseId), findsOneWidget);
  });

  testWidgets('renders in Chinese when the locale is zh-CN', (
    WidgetTester tester,
  ) async {
    final Map<String, String> zh = loadLocaleStrings('zh-CN');
    await pumpSettings(
      tester,
      const ToolsPage(),
      overrides: settingsOverrides(),
      locale: const Locale('zh', 'CN'),
    );

    expect(find.text(zh['nav.tools']!), findsOneWidget);
    expect(find.text(zh['perApp.title']!), findsOneWidget);
    expect(find.text(zh['mihomo.title']!), findsOneWidget);
  });
}
