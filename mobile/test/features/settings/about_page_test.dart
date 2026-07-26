import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/about/about.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late Map<String, String> en;

  setUp(() {
    resetSettingsTestEnvironment();
    en = loadLocaleStrings();
  });

  testWidgets('shows the app version, the licence and the notices links', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const AboutPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );

    expect(find.text(en['app.name']!), findsWidgets);
    expect(find.text(en['app.tagline']!), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('${en['about.buildNumber']!} 1'), findsOneWidget);

    // GPL-3.0 is a licence identifier, rendered verbatim, plus the two
    // compliance links §7 of the contract makes mandatory.
    expect(find.text(kAikoLicenseId), findsOneWidget);
    expect(find.byKey(const Key('about-license')), findsOneWidget);
    expect(find.byKey(const Key('about-third-party')), findsOneWidget);
    expect(find.byKey(const Key('about-security')), findsOneWidget);
    expect(find.text(en['about.thirdParty']!), findsOneWidget);
  });

  testWidgets('falls back to the version libbox reports for the core', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const AboutPage(),
      overrides: settingsOverrides(),
      surface: const Size(420, 1200),
    );
    expect(find.text('sing-box 1.13.0'), findsOneWidget);
  });

  testWidgets('prefers the version the running core reported', (
    WidgetTester tester,
  ) async {
    await pumpSettings(
      tester,
      const AboutPage(),
      overrides: settingsOverrides(
        status: const CoreStatus(state: CoreState.running, version: '1.13.4'),
      ),
      surface: const Size(420, 1200),
    );
    expect(find.text('1.13.4'), findsOneWidget);
  });

  testWidgets('copy diagnostics writes a report with no user data in it', (
    WidgetTester tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpSettings(
      tester,
      const AboutPage(),
      overrides: settingsOverrides(
        config: AppConfig.defaults.copyWith(
          splitTunnelMode: SplitTunnelMode.deny,
          splitTunnelPackages: const <String>['com.example.a'],
        ),
      ),
      surface: const Size(420, 1200),
    );

    await tester.tap(find.byKey(const Key('about-diagnostics')));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('AikoBox 0.1.0 (1)'));
    expect(copied, contains('package: $kTestPackageName'));
    expect(copied, contains('core: sing-box 1.13.0'));
    expect(copied, contains('splitTunnel: deny (1)'));
    // Package names of the user's chosen apps are counted, never listed.
    expect(copied, isNot(contains('com.example.a')));
    expect(find.text(en['common.copied']!), findsOneWidget);
  });
}
