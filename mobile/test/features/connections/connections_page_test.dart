import 'dart:async';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/connections/connection_detail_sheet.dart';
import 'package:aikobox_mobile/features/connections/connections_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  late StreamController<ConnectionsSnapshot> socket;
  late RecordingCoreController controller;
  late Map<String, String> en;
  late List<String> copied;

  setUp(() {
    socket = StreamController<ConnectionsSnapshot>.broadcast();
    controller = RecordingCoreController();
    en = loadLocaleStrings();
    copied = <String>[];
    addTearDown(socket.close);
  });

  /// A container wired to [socket], with the tunnel replaced by [controller].
  ///
  /// The `overrides` literal is deliberately untyped — see the harness.
  ProviderContainer makeContainer({
    CoreStatus? status,
    FakeAppConfigNotifier? config,
  }) => ProviderContainer.test(
    overrides: [
      coreStatusProvider.overrideWith(
        () => FakeCoreStatusNotifier(status ?? runningStatus),
      ),
      connectionsSnapshotProvider.overrideWith((Ref ref) => socket.stream),
      appConfigProvider.overrideWith(
        () => config ?? FakeAppConfigNotifier(AppConfig.defaults),
      ),
      coreControllerProvider.overrideWithValue(controller),
    ],
  );

  Future<void> pushFrame(
    WidgetTester tester,
    List<ConnectionInfo> connections, {
    int uploadTotal = 0,
    int downloadTotal = 0,
  }) async {
    socket.add(
      ConnectionsSnapshot(
        connections: connections,
        uploadTotal: uploadTotal,
        downloadTotal: downloadTotal,
      ),
    );
    await tester.pumpAndSettle();
  }

  void captureClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            ((call.arguments as Map<Object?, Object?>)['text'] as String?) ??
                '',
          );
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
  }

  testWidgets('shows the empty state until the core sends a frame', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    expect(find.text(en['connections.empty']!), findsOneWidget);

    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
    ]);
    expect(find.text(en['connections.empty']!), findsNothing);
    expect(find.text('example.com:443'), findsOneWidget);
  });

  testWidgets('says the core is not running when it is not', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(status: CoreStatus.stopped),
    );
    expect(find.text(en['dashboard.core.notRunning']!), findsOneWidget);
  });

  testWidgets('renders the origin, chain and byte counters of a row', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(
        id: 'a',
        host: 'example.com:443',
        process: 'com.example.app',
        chains: const <String>['HK-01', 'PROXY'],
        upload: 1024,
        download: 2048,
        type: 'Tun',
      ),
    ]);

    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('com.example.app'), findsOneWidget);
    // Outermost chain entry, the way the core orders it.
    expect(find.text('HK-01'), findsOneWidget);
    expect(find.text('Tun(TCP)'), findsOneWidget);
    expect(find.text('1.00 KB'), findsOneWidget);
    expect(find.text('2.00 KB'), findsWidgets);
  });

  testWidgets('the filter searches the whole record', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(id: 'b', host: 'tracker.net:80', process: 'com.other.app'),
    ]);
    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('tracker.net:80'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'com.other');
    await tester.pumpAndSettle();

    expect(find.text('example.com:443'), findsNothing);
    expect(find.text('tracker.net:80'), findsOneWidget);
  });

  testWidgets('closed connections move to the second tab', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(id: 'b', host: 'tracker.net:80'),
    ]);
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'b', host: 'tracker.net:80'),
    ]);

    expect(find.text('example.com:443'), findsNothing);

    await tester.tap(find.text(en['connections.closed']!));
    await tester.pumpAndSettle();

    expect(find.text('example.com:443'), findsOneWidget);
    expect(find.text('tracker.net:80'), findsNothing);
  });

  testWidgets('the close button on an active row closes that connection', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
    ]);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(controller.closedIds, <String>['a']);
  });

  testWidgets('close-all asks first, then makes one call', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a'),
      makeConnection(id: 'b'),
    ]);

    await tester.tap(find.byIcon(Icons.block_rounded));
    await tester.pumpAndSettle();
    expect(find.text(en['connections.closeConfirm.title']!), findsOneWidget);
    expect(controller.closeAllCalls, 0);

    await tester.tap(find.text(en['common.confirm']!));
    await tester.pumpAndSettle();

    expect(controller.closeAllCalls, 1);
    expect(controller.closedIds, isEmpty);
  });

  testWidgets('close-all with a filter closes only the visible ids', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(id: 'b', host: 'tracker.net:80'),
    ]);

    await tester.enterText(find.byType(TextField), 'tracker');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.block_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['common.confirm']!));
    await tester.pumpAndSettle();

    expect(controller.closeAllCalls, 0);
    expect(controller.closedIds, <String>['b']);
  });

  testWidgets('cancelling the confirmation closes nothing', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[makeConnection(id: 'a')]);

    await tester.tap(find.byIcon(Icons.block_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['common.cancel']!));
    await tester.pumpAndSettle();

    expect(controller.closeAllCalls, 0);
    expect(controller.closedIds, isEmpty);
  });

  testWidgets('pausing stops the lists updating', (WidgetTester tester) async {
    await pumpPage(tester, const ConnectionsPage(), container: makeContainer());
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
    ]);

    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pumpAndSettle();

    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(id: 'b', host: 'tracker.net:80'),
    ]);
    expect(find.text('tracker.net:80'), findsNothing);

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(id: 'b', host: 'tracker.net:80'),
    ]);
    expect(find.text('tracker.net:80'), findsOneWidget);
  });

  testWidgets('the detail sheet lists the metadata the core supplied', (
    WidgetTester tester,
  ) async {
    // Tall surface so the whole sheet is built: a ListView only builds what is
    // near the viewport, and this one has fourteen rows.
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(),
      surface: const Size(400, 1400),
    );
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(
        id: 'a',
        host: 'cdn.example.com:443',
        destinationIp: '93.184.216.34',
        sourceIp: '10.0.0.2',
        process: 'com.example.app',
        chains: const <String>['HK-01', 'PROXY'],
        rule: 'DomainSuffix',
        rulePayload: 'example.com',
      ),
    ]);

    await tester.tap(find.text('cdn.example.com:443'));
    await tester.pumpAndSettle();

    // Scoped to the sheet: the row underneath shows some of the same values.
    Finder inSheet(String text) => find.descendant(
      of: find.byType(ConnectionDetailSheet),
      matching: find.text(text),
    );

    expect(find.text(en['connections.detail.title']!), findsOneWidget);
    expect(inSheet('DomainSuffix(example.com)'), findsOneWidget);
    expect(inSheet('PROXY>>HK-01'), findsOneWidget);
    expect(inSheet('cdn.example.com'), findsOneWidget);
    expect(inSheet('93.184.216.34'), findsOneWidget);
    expect(inSheet('10.0.0.2'), findsOneWidget);
    expect(inSheet('443'), findsOneWidget);
    expect(inSheet('com.example.app'), findsOneWidget);
  });

  testWidgets('the detail sheet copies a generated Clash rule', (
    WidgetTester tester,
  ) async {
    captureClipboard(tester);
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(),
      surface: const Size(400, 1400),
    );
    await pushFrame(tester, <ConnectionInfo>[
      makeConnection(id: 'a', host: 'cdn.example.com:443'),
    ]);

    await tester.tap(find.text('cdn.example.com:443'));
    await tester.pumpAndSettle();

    // Connection type is the first row carrying a rule menu; the host row is
    // the next one, and is the one that generates DOMAIN-SUFFIX.
    await tester.tap(find.byTooltip(en['connections.detail.copyRule']!).at(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('DOMAIN-SUFFIX,example.com'));
    await tester.pumpAndSettle();

    expect(copied, <String>['DOMAIN-SUFFIX,example.com']);
    expect(find.text(en['connections.copyRuleSuccess']!), findsOneWidget);
  });

  testWidgets('the sort menu persists the field through AppConfig', (
    WidgetTester tester,
  ) async {
    final FakeAppConfigNotifier config = FakeAppConfigNotifier(
      AppConfig.defaults,
    );
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(config: config),
    );

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['connections.downloadAmount']!));
    await tester.pumpAndSettle();

    expect(config.state.connectionOrderBy, 'download');
    expect(config.state.connectionDirection, 'desc');
  });

  testWidgets('picking the field that is already selected flips direction', (
    WidgetTester tester,
  ) async {
    final FakeAppConfigNotifier config = FakeAppConfigNotifier(
      AppConfig.defaults,
    );
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(config: config),
    );
    expect(config.state.connectionOrderBy, 'time');
    expect(config.state.connectionDirection, 'desc');

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['connections.time']!));
    await tester.pumpAndSettle();

    expect(config.state.connectionOrderBy, 'time');
    expect(config.state.connectionDirection, 'asc');
  });

  testWidgets('a failing settings write is reported, not swallowed', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const ConnectionsPage(),
      container: makeContainer(
        config: FakeAppConfigNotifier(AppConfig.defaults, failWrites: true),
      ),
    );

    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['connections.uploadSpeed']!));
    await tester.pumpAndSettle();

    expect(
      find.text(en['common.error.updateAppConfigFailed']!),
      findsOneWidget,
    );
  });
}
