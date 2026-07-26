import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/logs/logs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

LogLine line(String level, String payload, {int second = 0}) => LogLine(
  level: level,
  payload: payload,
  time: DateTime.utc(2026, 7, 26, 12, 0, second),
);

void main() {
  late Map<String, String> en;

  setUp(() => en = loadLocaleStrings());

  ProviderContainer makeContainer(
    List<LogLine> lines, {
    CoreStatus? status,
    FakeLogsNotifier? logs,
  }) => ProviderContainer.test(
    overrides: [
      coreStatusProvider.overrideWith(
        () => FakeCoreStatusNotifier(status ?? runningStatus),
      ),
      logsProvider.overrideWith(() => logs ?? FakeLogsNotifier(lines)),
    ],
  );

  testWidgets('renders each line with its level and message', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[
        line('info', 'started listening', second: 1),
        line('error', 'dial tcp: refused', second: 2),
      ]),
    );

    expect(find.text('started listening'), findsOneWidget);
    expect(find.text('dial tcp: refused'), findsOneWidget);
    expect(find.text(en['mihomo.info']!), findsOneWidget);
    expect(find.text(en['mihomo.error']!), findsWidgets);
  });

  testWidgets('empty until the core says something', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[]),
    );
    expect(find.text(en['logs.empty']!), findsOneWidget);
  });

  testWidgets('says the core is not running when it is not', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[], status: CoreStatus.stopped),
    );
    expect(find.text(en['dashboard.core.notRunning']!), findsOneWidget);
  });

  testWidgets('the search box narrows the list', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[
        line('info', 'started listening'),
        line('info', 'dns lookup for example.com'),
      ]),
    );

    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.pumpAndSettle();

    expect(find.text('started listening'), findsNothing);
    expect(find.text('dns lookup for example.com'), findsOneWidget);
  });

  testWidgets('a search that matches nothing says so without lying', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[line('info', 'started listening')]),
    );

    await tester.enterText(find.byType(TextField), 'nothing here');
    await tester.pumpAndSettle();

    // Not "No logs yet" — there are logs, they just do not match.
    expect(find.text(en['common.emptyState']!), findsOneWidget);
    expect(find.text(en['logs.empty']!), findsNothing);
  });

  testWidgets('the level menu keeps only what is at least that severe', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[
        line('info', 'chatty'),
        line('warning', 'hmm'),
        line('error', 'boom'),
      ]),
    );

    await tester.tap(find.byIcon(Icons.filter_list_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['mihomo.warning']!).last);
    await tester.pumpAndSettle();

    expect(find.text('chatty'), findsNothing);
    expect(find.text('hmm'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('pausing freezes the list and shows why', (
    WidgetTester tester,
  ) async {
    final FakeLogsNotifier logs = FakeLogsNotifier(<LogLine>[
      line('info', 'before'),
    ]);
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(const <LogLine>[], logs: logs),
    );

    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pumpAndSettle();
    expect(find.text(en['logs.paused']!), findsOneWidget);

    logs.emit(line('info', 'after'));
    await tester.pumpAndSettle();
    expect(find.text('after'), findsNothing);

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(find.text('after'), findsOneWidget);
    expect(find.text(en['logs.paused']!), findsNothing);
  });

  testWidgets('clear empties the shared buffer', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[line('info', 'started listening')]),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en['logs.clear']!));
    await tester.pumpAndSettle();

    expect(find.text('started listening'), findsNothing);
    expect(find.text(en['logs.empty']!), findsOneWidget);
  });

  testWidgets('tapping a line copies it with its stamp and level', (
    WidgetTester tester,
  ) async {
    final List<String> copied = <String>[];
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

    await pumpPage(
      tester,
      const LogsPage(),
      container: makeContainer(<LogLine>[
        LogLine(
          level: 'error',
          payload: 'dial tcp: refused',
          // Local time, so the rendered stamp is deterministic in any zone.
          time: DateTime(2026, 7, 26, 14, 3, 9),
        ),
      ]),
    );

    await tester.tap(find.text('dial tcp: refused'));
    await tester.pumpAndSettle();

    expect(copied, <String>[
      '14:03:09 [${en['mihomo.error']}] dial tcp: refused',
    ]);
    expect(find.text(en['common.copied']!), findsOneWidget);
  });
}
