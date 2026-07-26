import 'package:aikobox_mobile/features/shell/home_shell.dart';
import 'package:aikobox_mobile/features/shell/shell_destination.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

/// Stand-ins for the four feature pages. The shell is written against
/// [ShellDestination] precisely so it can be exercised without them.
final List<ShellDestination> _destinations = <ShellDestination>[
  ShellDestination(
    id: kShellDashboardTab,
    labelKey: 'nav.dashboard',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard,
    builder: (BuildContext context) => const Text('page-dashboard'),
  ),
  ShellDestination(
    id: kShellProxiesTab,
    labelKey: 'nav.proxies',
    icon: Icons.article_outlined,
    selectedIcon: Icons.article,
    builder: (BuildContext context) => const Text('page-proxies'),
  ),
  ShellDestination(
    id: kShellProfilesTab,
    labelKey: 'nav.profiles',
    icon: Icons.folder_outlined,
    selectedIcon: Icons.folder,
    builder: (BuildContext context) => const Text('page-profiles'),
  ),
  ShellDestination(
    id: kShellToolsTab,
    labelKey: 'nav.tools',
    icon: Icons.construction_outlined,
    selectedIcon: Icons.construction,
    builder: (BuildContext context) => const Text('page-tools'),
  ),
];

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(hostShell(HomeShell(destinations: _destinations)));
  await tester.pumpAndSettle();
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

/// The shell's own `PopScope`, not any the navigator may have installed.
PopScope<Object?> _popScope(WidgetTester tester) =>
    tester.widget<PopScope<Object?>>(
      find.descendant(
        of: find.byType(HomeShell),
        matching: find.byType(PopScope<Object?>),
      ),
    );

void main() {
  group('adaptive layout', () {
    testWidgets('below 600 dp it uses a bottom NavigationBar', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Tools'), findsOneWidget);
    });

    testWidgets('at 600 dp and above it uses a NavigationRail', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(900, 800));

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('600 dp exactly is the rail, not the bar', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(600, 800));

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });
  });

  group('paging', () {
    testWidgets('the PageView never responds to a swipe', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));

      final PageView pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('tapping a destination selects it and moves the page', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));

      await tester.tap(find.text('Profiles'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      expect(_containerOf(tester).read(shellTabProvider), kShellProfilesTab);
      expect(find.text('page-profiles'), findsOneWidget);
    });

    testWidgets('selecting by id from outside the shell moves the page', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));

      _containerOf(
        tester,
      ).read(shellTabProvider.notifier).select(kShellToolsTab);
      await tester.pumpAndSettle();

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
      expect(find.text('page-tools'), findsOneWidget);
    });

    testWidgets('an unknown id falls back to the first destination', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));
      final ProviderContainer container = _containerOf(tester);

      container.read(shellTabProvider.notifier).select(kShellToolsTab);
      await tester.pumpAndSettle();
      container.read(shellTabProvider.notifier).select('does-not-exist');
      await tester.pumpAndSettle();

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
    });

    testWidgets('the rail drives the same state as the bar', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(900, 800));

      await tester.tap(find.text('Proxies'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
      );
      expect(_containerOf(tester).read(shellTabProvider), kShellProxiesTab);
    });
  });

  group('system back', () {
    testWidgets('back leaves the app only from the first destination', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));

      expect(_popScope(tester).canPop, isTrue);

      _containerOf(
        tester,
      ).read(shellTabProvider.notifier).select(kShellProfilesTab);
      await tester.pumpAndSettle();

      expect(_popScope(tester).canPop, isFalse);
    });

    testWidgets('an intercepted back returns to the first destination', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, const Size(400, 800));
      final ProviderContainer container = _containerOf(tester);

      container.read(shellTabProvider.notifier).select(kShellProfilesTab);
      await tester.pumpAndSettle();

      _popScope(tester).onPopInvokedWithResult?.call(false, null);
      await tester.pumpAndSettle();

      expect(container.read(shellTabProvider), kShellDashboardTab);
    });
  });
}
