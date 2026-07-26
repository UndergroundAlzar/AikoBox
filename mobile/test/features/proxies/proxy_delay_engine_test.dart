import 'dart:async';

import 'package:aikobox_mobile/features/proxies/proxy_delay_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A probe whose completion each caller controls, so concurrency can be
/// observed rather than inferred from timing.
class _FakeProbe {
  final Map<String, Completer<int?>> pending = <String, Completer<int?>>{};
  final List<String> started = <String>[];
  final List<String> urls = <String>[];
  int? timeoutMs;
  int inFlight = 0;
  int peakInFlight = 0;

  Future<int?> call(
    String node, {
    required String url,
    required int timeoutMs,
  }) {
    started.add(node);
    urls.add(url);
    this.timeoutMs = timeoutMs;
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    final completer = Completer<int?>();
    pending[node] = completer;
    return completer.future.whenComplete(() => inFlight--);
  }

  void answer(String node, int? delay) => pending.remove(node)!.complete(delay);

  void answerAll(int? delay) {
    for (final name in pending.keys.toList(growable: false)) {
      answer(name, delay);
    }
  }

  void fail(String node) =>
      pending.remove(node)!.completeError(StateError('probe blew up'));
}

List<String> _nodes(int count) => <String>[
  for (var i = 0; i < count; i++) 'n$i',
];

void main() {
  late _FakeProbe probe;
  late List<ProxyDelayState> published;
  late ProxyDelayEngine engine;

  setUp(() {
    probe = _FakeProbe();
    published = <ProxyDelayState>[];
    engine = ProxyDelayEngine(
      probe: probe.call,
      onState: published.add,
      flushInterval: const Duration(milliseconds: 200),
    );
  });

  tearDown(() => engine.dispose());

  group('testNode', () {
    test('marks the node testing, then publishes the measurement', () async {
      final future = engine.testNode('HK', url: 'https://x', timeoutMs: 1500);
      expect(engine.state.isTesting('HK'), isTrue);
      expect(published, hasLength(1));
      expect(probe.timeoutMs, 1500);
      expect(probe.urls.single, 'https://x');

      probe.answer('HK', 42);
      expect(await future, 42);

      expect(engine.state.isTesting('HK'), isFalse);
      expect(engine.state.delays['HK'], 42);
      expect(published, hasLength(2));
    });

    test('a probe that throws is a failed measurement, not an error', () async {
      final future = engine.testNode('HK', url: 'https://x', timeoutMs: 1000);
      probe.fail('HK');
      expect(await future, isNull);

      expect(
        engine.state.delays.containsKey('HK'),
        isTrue,
        reason: 'the key has to exist, or the grid falls back to core history',
      );
      expect(engine.state.delays['HK'], isNull);
      expect(engine.state.isTesting('HK'), isFalse);
    });
  });

  group('testGroup', () {
    test('never runs more probes at once than concurrency allows', () async {
      final future = engine.testGroup(
        'G',
        _nodes(10),
        url: 'https://x',
        timeoutMs: 1000,
        concurrency: 3,
      );
      await Future<void>.delayed(Duration.zero);
      expect(probe.started, hasLength(3));

      var guard = 0;
      while (probe.pending.isNotEmpty || probe.started.length < 10) {
        probe.answerAll(20);
        await Future<void>.delayed(Duration.zero);
        if (++guard > 100) fail('the sweep never drained');
      }
      await future;

      expect(probe.started, hasLength(10));
      expect(probe.peakInFlight, 3);
    });

    test('a concurrency above the ceiling is clamped, not honoured', () async {
      final future = engine.testGroup(
        'G',
        _nodes(200),
        url: 'https://x',
        timeoutMs: 1000,
        concurrency: 500,
      );
      await Future<void>.delayed(Duration.zero);
      expect(probe.started, hasLength(ProxyDelayEngine.maxConcurrency));

      var guard = 0;
      while (probe.pending.isNotEmpty || probe.started.length < 200) {
        probe.answerAll(20);
        await Future<void>.delayed(Duration.zero);
        if (++guard > 100) fail('the sweep never drained');
      }
      await future;
      expect(probe.peakInFlight, ProxyDelayEngine.maxConcurrency);
    });

    test('the whole group is marked testing in a single publish', () {
      unawaited(
        engine.testGroup(
          'G',
          _nodes(4),
          url: 'https://x',
          timeoutMs: 1000,
          concurrency: 4,
        ),
      );
      expect(published, hasLength(1));
      expect(engine.state.isGroupTesting('G'), isTrue);
      expect(engine.state.testingNodes, <String>{'n0', 'n1', 'n2', 'n3'});
    });

    testWidgets('results reach the grid in batches, not one at a time', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());

      unawaited(
        engine.testGroup(
          'G',
          _nodes(4),
          url: 'https://x',
          timeoutMs: 1000,
          concurrency: 4,
        ),
      );
      await tester.pump();
      expect(published, hasLength(1), reason: 'the "all testing" publish');

      probe.answer('n0', 10);
      probe.answer('n1', 20);
      probe.answer('n2', 30);
      await tester.pump();
      expect(
        published,
        hasLength(1),
        reason: 'three results landed and nothing repainted yet',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(published, hasLength(2), reason: 'one flush carried all three');
      expect(engine.state.delays, <String, int?>{'n0': 10, 'n1': 20, 'n2': 30});
      expect(engine.state.testingNodes, <String>{'n3'});
      expect(engine.state.isGroupTesting('G'), isTrue);

      probe.answer('n3', 40);
      await tester.pump();
      // The last result does not wait out the timer: the sweep flushes as it
      // finishes, which is also what clears the group's spinner.
      expect(published, hasLength(3));
      expect(engine.state.isGroupTesting('G'), isFalse);
      expect(engine.state.isIdle, isTrue);

      engine.dispose();
    });

    test('a second sweep of a group already under test is ignored', () async {
      unawaited(
        engine.testGroup(
          'G',
          _nodes(2),
          url: 'https://x',
          timeoutMs: 1000,
          concurrency: 2,
        ),
      );
      await engine.testGroup(
        'G',
        _nodes(2),
        url: 'https://x',
        timeoutMs: 1000,
        concurrency: 2,
      );
      expect(probe.started, hasLength(2));
    });

    test('an empty group does nothing at all', () async {
      await engine.testGroup(
        'G',
        const <String>[],
        url: 'https://x',
        timeoutMs: 1000,
        concurrency: 4,
      );
      expect(published, isEmpty);
      expect(probe.started, isEmpty);
    });
  });

  test('reset drops every measurement', () async {
    final future = engine.testNode('HK', url: 'https://x', timeoutMs: 1000);
    probe.answer('HK', 42);
    await future;
    expect(engine.state.delays, isNotEmpty);

    engine.reset();
    expect(engine.state, ProxyDelayState.empty);
  });

  test('nothing is published after dispose', () async {
    final future = engine.testNode('HK', url: 'https://x', timeoutMs: 1000);
    final before = published.length;
    engine.dispose();
    probe.answer('HK', 42);
    await future;

    expect(published, hasLength(before));
    expect(engine.isDisposed, isTrue);
  });
}
