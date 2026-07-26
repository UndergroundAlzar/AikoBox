import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/logs/logs_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

LogLine line(String level, String payload, {int second = 0}) => LogLine(
  level: level,
  payload: payload,
  time: DateTime.utc(2026, 7, 26, 12, 0, second),
);

ProviderContainer containerWith(List<LogLine> lines) => ProviderContainer.test(
  overrides: [logsProvider.overrideWith(() => FakeLogsNotifier(lines))],
);

void main() {
  group('logPassesLevel', () {
    test('null keeps everything', () {
      expect(logPassesLevel(line('debug', 'x'), null), isTrue);
    });

    test('error keeps only errors', () {
      expect(logPassesLevel(line('error', 'x'), LogLevel.error), isTrue);
      expect(logPassesLevel(line('warning', 'x'), LogLevel.error), isFalse);
      expect(logPassesLevel(line('info', 'x'), LogLevel.error), isFalse);
    });

    test('info keeps everything except debug', () {
      expect(logPassesLevel(line('error', 'x'), LogLevel.info), isTrue);
      expect(logPassesLevel(line('warning', 'x'), LogLevel.info), isTrue);
      expect(logPassesLevel(line('info', 'x'), LogLevel.info), isTrue);
      expect(logPassesLevel(line('debug', 'x'), LogLevel.info), isFalse);
    });

    test('understands the aliases the core sends', () {
      // LogLine.severity goes through LogLevel.fromWire, so `warn` and `fatal`
      // land on warning and error.
      expect(logPassesLevel(line('warn', 'x'), LogLevel.warning), isTrue);
      expect(logPassesLevel(line('fatal', 'x'), LogLevel.error), isTrue);
    });
  });

  group('logMatchesQuery', () {
    test('searches the payload', () {
      expect(logMatchesQuery(line('info', 'DNS lookup failed'), 'dns'), isTrue);
      expect(
        logMatchesQuery(line('info', 'DNS lookup failed'), 'tcp'),
        isFalse,
      );
    });

    test('searches the level name, as the desktop does', () {
      expect(logMatchesQuery(line('warning', 'anything'), 'warn'), isTrue);
    });

    test('an empty query matches everything', () {
      expect(logMatchesQuery(line('info', 'x'), ''), isTrue);
    });
  });

  test('logLevelLabelKey covers every level', () {
    for (final LogLevel level in LogLevel.values) {
      expect(logLevelLabelKey(level), startsWith('mihomo.'));
    }
  });

  group('visibleLogsProvider', () {
    test('is newest first', () {
      final ProviderContainer container = containerWith(<LogLine>[
        line('info', 'first', second: 1),
        line('info', 'second', second: 2),
      ]);
      expect(
        container
            .read(visibleLogsProvider)
            .map((LogLine l) => l.payload)
            .toList(),
        <String>['second', 'first'],
      );
    });

    test('never renders more than the hard cap', () {
      final ProviderContainer container = containerWith(<LogLine>[
        for (int i = 0; i < kLogsViewLineLimit + 500; i++)
          line('info', 'line-$i'),
      ]);
      final List<LogLine> visible = container.read(visibleLogsProvider);
      expect(visible.length, kLogsViewLineLimit);
      // The newest are the ones kept.
      expect(visible.first.payload, 'line-${kLogsViewLineLimit + 499}');
      expect(visible.last.payload, 'line-500');
    });

    test('applies the level filter', () {
      final ProviderContainer container = containerWith(<LogLine>[
        line('info', 'chatty'),
        line('error', 'boom'),
        line('warning', 'hmm'),
      ]);
      container.read(logsViewProvider.notifier).setLevel(LogLevel.warning);
      expect(
        container
            .read(visibleLogsProvider)
            .map((LogLine l) => l.payload)
            .toList(),
        <String>['hmm', 'boom'],
      );
    });

    test('applies the text filter, case-insensitively', () {
      final ProviderContainer container = containerWith(<LogLine>[
        line('info', 'DNS lookup for example.com'),
        line('info', 'TCP connect'),
      ]);
      container.read(logsViewProvider.notifier).setQuery('  EXAMPLE.COM ');
      expect(
        container.read(visibleLogsProvider).single.payload,
        'DNS lookup for example.com',
      );
    });

    test('pausing freezes the list against later lines', () {
      final ProviderContainer container = containerWith(<LogLine>[
        line('info', 'before'),
      ]);
      container.read(logsViewProvider.notifier).setPaused(paused: true);

      (container.read(logsProvider.notifier) as FakeLogsNotifier).emit(
        line('info', 'after'),
      );

      expect(container.read(visibleLogsProvider).length, 1);
      expect(container.read(visibleLogsProvider).single.payload, 'before');

      container.read(logsViewProvider.notifier).setPaused(paused: false);
      expect(
        container
            .read(visibleLogsProvider)
            .map((LogLine l) => l.payload)
            .toList(),
        <String>['after', 'before'],
      );
    });

    test('clear empties the view even while paused', () {
      final ProviderContainer container = containerWith(<LogLine>[
        line('info', 'before'),
      ]);
      container.read(logsViewProvider.notifier).setPaused(paused: true);
      container.read(logsViewProvider.notifier).clear();
      expect(container.read(visibleLogsProvider), isEmpty);
      expect(container.read(logsProvider), isEmpty);
    });
  });
}
