/// Latency probing for the proxies page: a bounded number of probes in flight
/// and one repaint per batch of results.
///
/// Why this exists rather than a `for` loop over `testDelay`: a URL test on a
/// 500-node group produces 500 results. Folding each one into the grid as it
/// lands is 500 rebuilds of a list that is already expensive to lay out, and
/// the desktop app hit exactly that — `proxies.tsx` buffers results in a ref
/// and flushes on a 200 ms timer for the same reason. This is that mechanism,
/// with the concurrency gate from `delayTestConcurrency` around it.
///
/// The engine holds no Riverpod or platform dependency: it takes a [probe]
/// callback and reports through [ProxyDelayEngine.onState]. `proxies_providers.dart`
/// is what binds it to the Clash API.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Measures one outbound. Returns milliseconds, or `null` when the probe
/// failed — which is a normal answer, not an error.
typedef ProxyDelayProbe =
    Future<int?> Function(
      String node, {
      required String url,
      required int timeoutMs,
    });

/// Everything the grid needs to know about probes in flight and their results.
@immutable
class ProxyDelayState {
  const ProxyDelayState({
    this.delays = const <String, int?>{},
    this.testingNodes = const <String>{},
    this.testingGroups = const <String>{},
  });

  static const ProxyDelayState empty = ProxyDelayState();

  /// Measurements taken this session, keyed by node name. A key present with a
  /// `null` value means "probed, and it failed" — distinct from an absent key,
  /// which means the core's own history is still the best answer.
  final Map<String, int?> delays;

  final Set<String> testingNodes;
  final Set<String> testingGroups;

  bool isTesting(String node) => testingNodes.contains(node);

  bool isGroupTesting(String group) => testingGroups.contains(group);

  bool get isIdle => testingNodes.isEmpty && testingGroups.isEmpty;

  ProxyDelayState copyWith({
    Map<String, int?>? delays,
    Set<String>? testingNodes,
    Set<String>? testingGroups,
  }) => ProxyDelayState(
    delays: delays ?? this.delays,
    testingNodes: testingNodes ?? this.testingNodes,
    testingGroups: testingGroups ?? this.testingGroups,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyDelayState &&
          mapEquals(other.delays, delays) &&
          setEquals(other.testingNodes, testingNodes) &&
          setEquals(other.testingGroups, testingGroups);

  @override
  int get hashCode =>
      Object.hash(delays.length, testingNodes.length, testingGroups.length);

  @override
  String toString() =>
      'ProxyDelayState(${delays.length} measured, '
      '${testingNodes.length} in flight)';
}

/// Runs delay probes and publishes batched results.
class ProxyDelayEngine {
  ProxyDelayEngine({
    required this.probe,
    required this.onState,
    this.flushInterval = const Duration(milliseconds: 200),
  });

  final ProxyDelayProbe probe;

  /// Called on every published state. Exactly once per batch, never per result.
  final void Function(ProxyDelayState state) onState;

  /// How long results accumulate before they reach the grid.
  final Duration flushInterval;

  /// Ceiling on [testGroup]'s concurrency, whatever the setting asks for. A
  /// phone opening 500 sockets at once loses more to contention than it gains.
  static const int maxConcurrency = 64;

  final Map<String, int?> _pendingDelays = <String, int?>{};
  final Set<String> _pendingDone = <String>{};

  ProxyDelayState _state = ProxyDelayState.empty;
  Timer? _flushTimer;
  bool _disposed = false;

  ProxyDelayState get state => _state;

  bool get isDisposed => _disposed;

  /// Probes one node and publishes the result immediately: a single tap is not
  /// worth batching, and the spinner has to stop the moment the answer lands.
  Future<int?> testNode(
    String node, {
    required String url,
    required int timeoutMs,
  }) async {
    if (_disposed || node.isEmpty) return null;

    _publish(
      _state.copyWith(testingNodes: <String>{..._state.testingNodes, node}),
    );

    final result = await _probeOnce(node, url: url, timeoutMs: timeoutMs);
    if (_disposed) return result;

    // Fold in anything a concurrent group test has buffered so the two paths
    // cannot clobber each other's results.
    final delays = <String, int?>{
      ..._state.delays,
      ..._pendingDelays,
      node: result,
    };
    _pendingDelays.clear();
    final testingNodes = Set<String>.of(_state.testingNodes)
      ..removeAll(_pendingDone)
      ..remove(node);
    _pendingDone.clear();

    _publish(_state.copyWith(delays: delays, testingNodes: testingNodes));
    return result;
  }

  /// Probes every member of [group], at most [concurrency] at a time, flushing
  /// whatever has landed every [flushInterval].
  ///
  /// Returns when the last probe has been folded in. A second call for a group
  /// already under test is ignored rather than queued.
  Future<void> testGroup(
    String group,
    List<String> nodes, {
    required String url,
    required int timeoutMs,
    required int concurrency,
  }) async {
    if (_disposed || nodes.isEmpty) return;
    if (_state.testingGroups.contains(group)) return;

    final queue = List<String>.of(nodes);
    _publish(
      _state.copyWith(
        testingNodes: <String>{..._state.testingNodes, ...queue},
        testingGroups: <String>{..._state.testingGroups, group},
      ),
    );

    var cursor = 0;
    Future<void> worker() async {
      while (!_disposed) {
        final index = cursor++;
        if (index >= queue.length) return;
        final name = queue[index];
        final result = await _probeOnce(name, url: url, timeoutMs: timeoutMs);
        _pendingDelays[name] = result;
        _pendingDone.add(name);
        _scheduleFlush();
      }
    }

    final lanes = concurrency.clamp(1, maxConcurrency);
    await Future.wait(<Future<void>>[
      for (var lane = 0; lane < lanes && lane < queue.length; lane++) worker(),
    ]);

    if (_disposed) return;
    _flush(finishedGroup: group, clearNodes: queue.toSet());
  }

  /// Drops every measurement. Called when the core stops, because a delay from
  /// the previous session says nothing about this one.
  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingDelays.clear();
    _pendingDone.clear();
    if (_disposed) return;
    _publish(ProxyDelayState.empty);
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingDelays.clear();
    _pendingDone.clear();
  }

  Future<int?> _probeOnce(
    String node, {
    required String url,
    required int timeoutMs,
  }) async {
    try {
      return await probe(node, url: url, timeoutMs: timeoutMs);
    } catch (_) {
      // A refused probe and a timed-out probe are the same fact to the user:
      // this node did not answer.
      return null;
    }
  }

  void _scheduleFlush() {
    if (_disposed || _flushTimer != null) return;
    _flushTimer = Timer(flushInterval, () {
      _flushTimer = null;
      _flush();
    });
  }

  void _flush({String? finishedGroup, Set<String>? clearNodes}) {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed) return;

    final hasResults = _pendingDelays.isNotEmpty || _pendingDone.isNotEmpty;
    final hasCleanup =
        finishedGroup != null || (clearNodes != null && clearNodes.isNotEmpty);
    if (!hasResults && !hasCleanup) return;

    final delays = _pendingDelays.isEmpty
        ? _state.delays
        : <String, int?>{..._state.delays, ..._pendingDelays};
    final testingNodes = Set<String>.of(_state.testingNodes)
      ..removeAll(_pendingDone)
      ..removeAll(clearNodes ?? const <String>{});
    final testingGroups = finishedGroup == null
        ? _state.testingGroups
        : (Set<String>.of(_state.testingGroups)..remove(finishedGroup));

    _pendingDelays.clear();
    _pendingDone.clear();

    _publish(
      ProxyDelayState(
        delays: delays,
        testingNodes: testingNodes,
        testingGroups: testingGroups,
      ),
    );
  }

  void _publish(ProxyDelayState next) {
    if (_disposed || next == _state) return;
    _state = next;
    onState(next);
  }
}
