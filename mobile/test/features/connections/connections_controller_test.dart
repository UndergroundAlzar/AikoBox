import 'dart:async';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/connections/connections_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// Builds a container whose `/connections` socket is [source] and whose core is
/// reported by [status].
({ProviderContainer container, FakeCoreStatusNotifier core}) makeContainer(
  Stream<ConnectionsSnapshot> source, {
  CoreStatus? status,
}) {
  final FakeCoreStatusNotifier core = FakeCoreStatusNotifier(
    status ?? runningStatus,
  );
  // The list literal is intentionally untyped: `Override` is not re-exported
  // by flutter_riverpod, and inference from the parameter type saves an import
  // of a package this project only depends on transitively.
  final ProviderContainer container = ProviderContainer.test(
    overrides: [
      coreStatusProvider.overrideWith(() => core),
      connectionsSnapshotProvider.overrideWith((Ref ref) => source),
    ],
  );
  // Builds the notifier eagerly, which is what wires its stream listener up.
  container.listen<ConnectionsFeedState>(
    connectionsFeedProvider,
    (ConnectionsFeedState? previous, ConnectionsFeedState next) {},
    fireImmediately: true,
  );
  return (container: container, core: core);
}

ConnectionsSnapshot snapshotOf(
  List<ConnectionInfo> connections, {
  int uploadTotal = 0,
  int downloadTotal = 0,
}) => ConnectionsSnapshot(
  connections: connections,
  uploadTotal: uploadTotal,
  downloadTotal: downloadTotal,
);

void main() {
  group('ConnectionSortField', () {
    test('round-trips the AppConfig wire names', () {
      for (final ConnectionSortField field in ConnectionSortField.values) {
        expect(ConnectionSortField.fromWire(field.wireName), field);
      }
    });

    test('falls back to time for anything unrecognised', () {
      expect(ConnectionSortField.fromWire('nonsense'), ConnectionSortField.time);
      expect(ConnectionSortField.fromWire(null), ConnectionSortField.time);
    });
  });

  group('filterConnections', () {
    final List<ConnectionInfo> source = <ConnectionInfo>[
      makeConnection(id: 'a', host: 'example.com:443'),
      makeConnection(
        id: 'b',
        host: 'analytics.tracker.net:80',
        process: 'com.other.app',
      ),
    ];

    test('returns the same list when there is nothing to filter', () {
      expect(identical(filterConnections(source, '   '), source), isTrue);
    });

    test('matches anywhere in the record, case-insensitively', () {
      expect(
        filterConnections(
          source,
          'TRACKER',
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['b'],
      );
      expect(
        filterConnections(
          source,
          'com.other',
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['b'],
      );
    });

    test('matches on the outbound chain', () {
      final List<ConnectionInfo> withChains = <ConnectionInfo>[
        makeConnection(id: 'a', chains: const <String>['DIRECT']),
        makeConnection(id: 'b', chains: const <String>['HK-01', 'PROXY']),
      ];
      expect(
        filterConnections(
          withChains,
          'hk-01',
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['b'],
      );
    });
  });

  group('sortConnections', () {
    final DateTime base = DateTime.utc(2026, 7, 26, 12);
    final List<ConnectionInfo> source = <ConnectionInfo>[
      makeConnection(id: 'b', start: base.add(const Duration(seconds: 2)), download: 10),
      makeConnection(id: 'a', start: base, download: 30),
      makeConnection(id: 'c', start: base.add(const Duration(seconds: 1)), download: 20),
    ];

    test('orders by start time', () {
      expect(
        sortConnections(
          source,
          field: ConnectionSortField.time,
          ascending: true,
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['a', 'c', 'b'],
      );
    });

    test('reverses on descending', () {
      expect(
        sortConnections(
          source,
          field: ConnectionSortField.time,
          ascending: false,
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['b', 'c', 'a'],
      );
    });

    test('orders by a byte counter', () {
      expect(
        sortConnections(
          source,
          field: ConnectionSortField.download,
          ascending: false,
        ).map((ConnectionInfo c) => c.id).toList(),
        <String>['a', 'c', 'b'],
      );
    });

    test('breaks ties deterministically instead of shuffling', () {
      // Every speed is zero here, which is the normal case; without the
      // tie-break the unstable sort would reorder rows every frame.
      final List<ConnectionInfo> tied = <ConnectionInfo>[
        makeConnection(id: 'z', start: base),
        makeConnection(id: 'y', start: base),
        makeConnection(id: 'x', start: base),
      ];
      final List<String> once = sortConnections(
        tied,
        field: ConnectionSortField.uploadSpeed,
        ascending: true,
      ).map((ConnectionInfo c) => c.id).toList();
      final List<String> twice = sortConnections(
        tied.reversed.toList(),
        field: ConnectionSortField.uploadSpeed,
        ascending: true,
      ).map((ConnectionInfo c) => c.id).toList();
      expect(once, <String>['x', 'y', 'z']);
      expect(twice, once);
    });

    test('leaves the source list untouched', () {
      final List<String> before =
          source.map((ConnectionInfo c) => c.id).toList();
      sortConnections(
        source,
        field: ConnectionSortField.download,
        ascending: true,
      );
      expect(source.map((ConnectionInfo c) => c.id).toList(), before);
    });
  });

  group('ConnectionsFeedNotifier', () {
    late StreamController<ConnectionsSnapshot> socket;
    late ProviderContainer container;
    late FakeCoreStatusNotifier core;

    setUp(() {
      socket = StreamController<ConnectionsSnapshot>.broadcast();
      final ({ProviderContainer container, FakeCoreStatusNotifier core})
      made = makeContainer(socket.stream);
      container = made.container;
      core = made.core;
      addTearDown(socket.close);
    });

    ConnectionsFeedState read() => container.read(connectionsFeedProvider);

    Future<void> push(List<ConnectionInfo> connections, {int up = 0}) async {
      socket.add(snapshotOf(connections, uploadTotal: up));
      await pumpEventQueue();
    }

    test('starts empty', () {
      expect(read().active, isEmpty);
      expect(read().closed, isEmpty);
      expect(read().paused, isFalse);
    });

    test('publishes the frame it is given', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
      ], up: 4096);
      expect(read().active.map((ConnectionInfo c) => c.id), <String>['a', 'b']);
      expect(read().uploadTotal, 4096);
      expect(read().closed, isEmpty);
    });

    test('moves a connection to closed once the core stops reporting it', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a', upload: 111),
        makeConnection(id: 'b'),
      ]);
      await push(<ConnectionInfo>[makeConnection(id: 'b')]);

      expect(read().active.map((ConnectionInfo c) => c.id), <String>['b']);
      expect(read().closed.map((ConnectionInfo c) => c.id), <String>['a']);
      // The final counters of the closed connection survive.
      expect(read().closed.single.upload, 111);
    });

    test('zeroes the speeds of a closed connection', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a', uploadSpeed: 900, downloadSpeed: 700),
      ]);
      await push(<ConnectionInfo>[]);
      expect(read().closed.single.uploadSpeed, 0);
      expect(read().closed.single.downloadSpeed, 0);
    });

    test('does not resurrect a connection that reappears', () async {
      await push(<ConnectionInfo>[makeConnection(id: 'a')]);
      await push(<ConnectionInfo>[]);
      expect(read().closed.map((ConnectionInfo c) => c.id), <String>['a']);
      await push(<ConnectionInfo>[makeConnection(id: 'a')]);
      expect(read().active.map((ConnectionInfo c) => c.id), <String>['a']);
      expect(read().closed, isEmpty);
    });

    test('caps the closed buffer and keeps the newest records', () {
      // Driven straight through ingest: 250 round trips through the event
      // queue would make this the slowest test in the suite for no gain.
      final ConnectionsFeedNotifier notifier = container.read(
        connectionsFeedProvider.notifier,
      );
      const int churn = kClosedConnectionBufferLimit + 50;
      for (int i = 0; i < churn; i++) {
        notifier.ingest(
          snapshotOf(<ConnectionInfo>[
            makeConnection(id: 'stable'),
            makeConnection(id: 'churn-$i'),
          ]),
        );
      }
      notifier.ingest(
        snapshotOf(<ConnectionInfo>[makeConnection(id: 'stable')]),
      );

      expect(read().closed.length, kClosedConnectionBufferLimit);
      expect(read().closed.last.id, 'churn-${churn - 1}');
      expect(
        read().closed.first.id,
        'churn-${churn - kClosedConnectionBufferLimit}',
      );
    });

    test('drops frames while paused and picks up again on resume', () async {
      await push(<ConnectionInfo>[makeConnection(id: 'a')]);
      container
          .read(connectionsFeedProvider.notifier)
          .setPaused(paused: true);

      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
      ]);
      expect(read().active.map((ConnectionInfo c) => c.id), <String>['a']);

      container
          .read(connectionsFeedProvider.notifier)
          .setPaused(paused: false);
      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
      ]);
      expect(read().active.map((ConnectionInfo c) => c.id), <String>['a', 'b']);
    });

    test('dismissClosed removes a record for good', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
      ]);
      await push(<ConnectionInfo>[makeConnection(id: 'b')]);
      expect(read().closed.map((ConnectionInfo c) => c.id), <String>['a']);

      container.read(connectionsFeedProvider.notifier).dismissClosed('a');
      expect(read().closed, isEmpty);

      // A further frame must not bring it back from the retained history.
      await push(<ConnectionInfo>[makeConnection(id: 'b')]);
      expect(read().closed, isEmpty);
    });

    test('clearClosed empties the tab, and can clear a subset', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
        makeConnection(id: 'c'),
      ]);
      await push(<ConnectionInfo>[makeConnection(id: 'c')]);
      expect(read().closed.length, 2);

      container.read(connectionsFeedProvider.notifier).clearClosed(
        ids: <String>{'a'},
      );
      expect(read().closed.map((ConnectionInfo c) => c.id), <String>['b']);

      container.read(connectionsFeedProvider.notifier).clearClosed();
      expect(read().closed, isEmpty);
      await push(<ConnectionInfo>[makeConnection(id: 'c')]);
      expect(read().closed, isEmpty);
    });

    test('retires everything when the core stops', () async {
      await push(<ConnectionInfo>[
        makeConnection(id: 'a'),
        makeConnection(id: 'b'),
      ]);
      core.emit(const CoreStatus(state: CoreState.stopped));
      await pumpEventQueue();

      expect(read().active, isEmpty);
      expect(read().closed.map((ConnectionInfo c) => c.id), <String>['a', 'b']);
    });
  });
}
