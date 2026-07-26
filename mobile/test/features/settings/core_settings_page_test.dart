import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/settings/settings.dart';
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

  AppConfig configOf(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(CoreSettingsPage)),
    listen: false,
  ).read(appConfigProvider);

  Future<void> pumpCore(
    WidgetTester tester, {
    AppConfig config = AppConfig.defaults,
    CoreStatus status = CoreStatus.stopped,
    CoreController? controller,
  }) => pumpSettings(
    tester,
    const CoreSettingsPage(),
    overrides: settingsOverrides(
      config: config,
      status: status,
      controller: controller,
    ),
    surface: const Size(420, 1600),
  );

  testWidgets('outbound mode is inert while the core is down', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);

    expect(find.text(en['dashboard.core.notRunning']!), findsOneWidget);
    final ChoiceChip chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, en['outbound.modes.global']!),
    );
    expect(chip.onSelected, isNull);
  });

  testWidgets('a running core can switch outbound mode', (
    WidgetTester tester,
  ) async {
    await pumpCore(
      tester,
      status: const CoreStatus(state: CoreState.running, version: '1.13.0'),
    );

    await tester.tap(
      find.widgetWithText(ChoiceChip, en['outbound.modes.global']!),
    );
    await tester.pumpAndSettle();

    expect(FakeOutboundModeNotifier.applied, <OutboundMode>[
      OutboundMode.global,
    ]);
  });

  testWidgets('the core version falls back to what libbox reports', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);
    // FakeCoreChannel.coreVersion(), because CoreStatus.stopped has no version.
    expect(find.text('sing-box 1.13.0'), findsOneWidget);
  });

  testWidgets('restart is inert while the core is down', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);
    // SettingsValueTile puts the key on the ListTile itself.
    expect(
      tester.widget<ListTile>(find.byKey(const Key('core-restart'))).onTap,
      isNull,
    );
  });

  testWidgets('restart stops then starts the running core', (
    WidgetTester tester,
  ) async {
    final RecordingCoreController controller = RecordingCoreController();
    await pumpCore(
      tester,
      status: const CoreStatus(state: CoreState.running, version: '1.13.0'),
      controller: controller,
    );

    await tester.tap(find.byKey(const Key('core-restart')));
    await tester.pumpAndSettle();

    expect(controller.stopCalls, 1);
    expect(controller.startCalls, 1);
  });

  testWidgets('auto-redirect persists and warns that a restart is needed', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);

    expect(configOf(tester).autoRedirect, isFalse);
    expect(
      find.text(en['common.notification.restartRequired']!),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('core-auto-redirect')));
    await tester.pumpAndSettle();

    expect(configOf(tester).autoRedirect, isTrue);
  });

  testWidgets('close-connections-on-switch persists', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);
    expect(configOf(tester).autoCloseConnection, isTrue);

    await tester.tap(find.byKey(const Key('core-auto-close-connection')));
    await tester.pumpAndSettle();

    expect(configOf(tester).autoCloseConnection, isFalse);
  });

  testWidgets('the log level picker writes the chosen level', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);
    expect(configOf(tester).logLevel, LogLevel.info);

    await tester.tap(find.byKey(const Key('core-log-level')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('aiko-option-LogLevel.debug')));
    await tester.pumpAndSettle();

    expect(configOf(tester).logLevel, LogLevel.debug);
    expect(find.text(en['mihomo.debug']!), findsOneWidget);
  });

  testWidgets('the delay-test URL sheet refuses anything that is not http(s)', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);

    await tester.tap(find.byKey(const Key('core-delay-url')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('aiko-text-sheet-field')),
      'not a url',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('aiko-text-sheet-save')))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('aiko-text-sheet-field')),
      'https://cp.cloudflare.com/generate_204',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiko-text-sheet-save')));
    await tester.pumpAndSettle();

    expect(
      configOf(tester).delayTestUrl,
      'https://cp.cloudflare.com/generate_204',
    );
  });

  testWidgets('the concurrency sheet clamps to the supported range', (
    WidgetTester tester,
  ) async {
    await pumpCore(tester);

    await tester.tap(find.byKey(const Key('core-delay-concurrency')));
    await tester.pumpAndSettle();

    // 999 is outside 1..64, so the sheet refuses to commit it.
    await tester.enterText(
      find.byKey(const Key('aiko-text-sheet-field')),
      '999',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('aiko-text-sheet-save')))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('aiko-text-sheet-field')), '8');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('aiko-text-sheet-save')));
    await tester.pumpAndSettle();

    expect(configOf(tester).delayTestConcurrency, 8);
  });
}
