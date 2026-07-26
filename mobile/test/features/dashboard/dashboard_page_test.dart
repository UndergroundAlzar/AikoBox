import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/cards/log_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/outbound_mode_card.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const ProfileItem _profile = ProfileItem(id: 'p1', type: 'local', name: 'Home');

/// Lets a modal sheet finish its entrance animation.
Future<void> _settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(primeEnglish);
  tearDown(AikoL10n.resetForTests);

  group('layout', () {
    testWidgets('renders the title, the FAB and every default card', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.byType(AikoFab), findsOneWidget);
      expect(find.byType(StaggeredGrid), findsOneWidget);
      expect(find.byType(DashboardCard), findsNWidgets(kDashboardCards.length));
    });

    testWidgets('a hidden card is not built at all', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        config: AppConfig.defaults.copyWith(
          cardStatus: <String, CardStatus>{
            ...defaultDashboardCardStatus(),
            'log': CardStatus.hidden,
          },
        ),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.byType(LogCard), findsNothing);
      expect(
        find.byType(DashboardCard),
        findsNWidgets(kDashboardCards.length - 1),
      );
    });

    testWidgets('hiding everything leaves an empty state, not a blank page', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        config: AppConfig.defaults.copyWith(
          cardStatus: <String, CardStatus>{
            for (final DashboardCardSpec spec in kDashboardCards)
              spec.key: CardStatus.hidden,
          },
        ),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.byType(StaggeredGrid), findsNothing);
      expect(find.byType(EmptyState), findsOneWidget);
    });

    testWidgets('a 2-column card is twice as wide as a 1-column one', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        config: AppConfig.defaults.copyWith(
          cardOrder: <String>['mode', 'proxy', 'connection'],
          cardStatus: <String, CardStatus>{
            for (final DashboardCardSpec spec in kDashboardCards)
              spec.key: CardStatus.hidden,
            'mode': CardStatus.colSpan2,
            'proxy': CardStatus.colSpan1,
            'connection': CardStatus.colSpan1,
          },
        ),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.byType(OutboundModeCard), findsOneWidget);
      final double wide = tester
          .getSize(find.byType(DashboardCard).at(0))
          .width;
      final double narrow = tester
          .getSize(find.byType(DashboardCard).at(1))
          .width;
      // Two cells plus the gutter between them.
      expect(wide, narrow * 2 + AikoDims.gridSpacing);
    });
  });

  group('start / stop', () {
    testWidgets('with no profile the FAB explains instead of starting', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      expect(find.text('No profile selected'), findsWidgets);
      expect(harness.controller.startCalls, 0);
    });

    testWidgets('consent already granted starts without an extra prompt', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(profile: _profile);
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      expect(harness.channel.prepareCalls, 1);
      expect(harness.controller.startCalls, 1);
      expect(find.text('VPN permission required'), findsNothing);
    });

    testWidgets('N5: consent is explained before Android asks for it', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        channel: FakeCoreChannel(consentGranted: false),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      expect(find.text('VPN permission required'), findsOneWidget);
      expect(harness.controller.startCalls, 0);

      await tester.tap(find.text('Continue'));
      await _settleSheet(tester);

      expect(harness.controller.startCalls, 1);
    });

    testWidgets('backing out of the explanation starts nothing', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        channel: FakeCoreChannel(consentGranted: false),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);
      await tester.tap(find.text('Cancel'));
      await _settleSheet(tester);

      expect(harness.controller.startCalls, 0);
    });

    testWidgets('stopping is confirmed first', (WidgetTester tester) async {
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        status: const CoreStatus(state: CoreState.running),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      expect(find.text('Stop the tunnel?'), findsOneWidget);
      expect(harness.controller.stopCalls, 0);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await _settleSheet(tester);

      expect(harness.controller.stopCalls, 1);
    });

    testWidgets('the FAB is inert while a transition is in flight', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        status: const CoreStatus(state: CoreState.starting),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(tester.widget<AikoFab>(find.byType(AikoFab)).onPressed, isNull);
      expect(tester.widget<AikoFab>(find.byType(AikoFab)).busy, isTrue);
    });

    testWidgets('N4: a converter refusal is shown verbatim', (
      WidgetTester tester,
    ) async {
      const String refusal =
          'Refusing to convert: proxy "HK 01" uses an unsupported cipher.';
      final FakeCoreController controller = FakeCoreController()
        ..startError = const CoreStartException(
          CoreStartException.codeConversionRefused,
          refusal,
          details: <String>[refusal],
        );
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        controller: controller,
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      // Once as the headline message, once in the verbatim details block.
      expect(find.text(refusal), findsWidgets);
    });

    testWidgets('a declined system prompt gets its own explanation', (
      WidgetTester tester,
    ) async {
      final FakeCoreController controller = FakeCoreController()
        ..startError = const CoreStartException(
          CoreStartException.codeVpnPermissionDenied,
          'VPN permission was not granted',
        );
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        controller: controller,
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byType(AikoFab));
      await _settleSheet(tester);

      expect(find.text('VPN permission denied'), findsOneWidget);
    });
  });

  group('status strip', () {
    testWidgets('a running-with-error state is surfaced and dismissable', (
      WidgetTester tester,
    ) async {
      const String message = 'The core rejected the configuration';
      final DashboardHarness harness = DashboardHarness(
        profile: _profile,
        status: const CoreStatus(state: CoreState.running, error: message),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.text(message), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(find.text(message), findsNothing);
    });

    testWidgets('a stopped core says so', (WidgetTester tester) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      expect(find.text('Stopped'), findsOneWidget);
    });
  });

  group('layout editor', () {
    testWidgets('hiding a card from the sheet persists to AppConfig', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byIcon(Icons.dashboard_customize_outlined));
      await _settleSheet(tester);

      expect(find.text('Dashboard Cards'), findsOneWidget);

      // Hide the first card in the editor's list.
      final String firstKey = resolveDashboardCardOrder(
        harness.config.cardOrder,
      ).first;
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey<String>('layout-row-$firstKey')),
              matching: find.byIcon(Icons.visibility_off_rounded),
            )
            .first,
      );
      await tester.pump();

      expect(harness.config.statusOfCard(firstKey), CardStatus.hidden);
    });

    testWidgets('reset restores the default order and sizes', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        config: AppConfig.defaults.copyWith(
          cardOrder: <String>['log', 'dns'],
          cardStatus: <String, CardStatus>{
            ...defaultDashboardCardStatus(),
            'log': CardStatus.hidden,
          },
        ),
      );
      await pumpDashboardWidget(
        tester,
        const DashboardPage(),
        harness: harness,
      );

      await tester.tap(find.byIcon(Icons.dashboard_customize_outlined));
      await _settleSheet(tester);
      await tester.tap(find.text('Restore Default Layout'));
      await tester.pump();

      expect(
        harness.config.cardOrder,
        resolveDashboardCardOrder(const <String>[]),
      );
      expect(harness.config.statusOfCard('log'), CardStatus.colSpan1);
    });
  });
}
