/// Where the proxies page meets the core layer.
///
/// Kept apart from the rest of the feature so everything else — the geometry,
/// the filters, the batching engine, the widgets — stays free of
/// `core/providers.dart` and can be unit-tested without a running tunnel.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'proxy_delay_engine.dart';

/// Owns the [ProxyDelayEngine] and publishes its batched state.
///
/// Selection does **not** go through here: it goes through
/// `proxiesProvider.notifier.select`, which reaches `CoreController.selectProxy`
/// — and that is what closes every live connection when `autoCloseConnection`
/// is on. Doing it a second time here would tear down connections the new
/// outbound had already opened.
class ProxyDelayNotifier extends Notifier<ProxyDelayState> {
  late ProxyDelayEngine _engine;

  @override
  ProxyDelayState build() {
    final engine = ProxyDelayEngine(probe: _probe, onState: _publish);
    _engine = engine;
    ref.onDispose(engine.dispose);

    // A latency measured against the core that just went away says nothing
    // about the next one, so the overlay is dropped rather than shown stale.
    ref.listen<CoreStatus>(coreStatusProvider, (
      CoreStatus? _,
      CoreStatus next,
    ) {
      if (!next.isRunning) engine.reset();
    });

    return ProxyDelayState.empty;
  }

  void _publish(ProxyDelayState next) {
    if (ref.mounted) state = next;
  }

  Future<int?> _probe(
    String node, {
    required String url,
    required int timeoutMs,
  }) async {
    final api = await ref.read(clashApiProvider.future);
    return api.proxyDelay(node, url: url, timeoutMs: timeoutMs);
  }

  /// Probes one node. [testUrl] is the group's own `testUrl` when it has one.
  Future<int?> testNode(String node, {String? testUrl}) {
    final config = ref.read(appConfigProvider);
    return _engine.testNode(
      node,
      url: _resolveUrl(testUrl, config),
      timeoutMs: config.delayTestTimeout,
    );
  }

  /// Probes a whole group, `delayTestConcurrency` probes at a time.
  Future<void> testGroup(String group, List<String> nodes, {String? testUrl}) {
    final config = ref.read(appConfigProvider);
    return _engine.testGroup(
      group,
      nodes,
      url: _resolveUrl(testUrl, config),
      timeoutMs: config.delayTestTimeout,
      concurrency: config.delayTestConcurrency,
    );
  }

  /// Forgets every measurement taken this session.
  void reset() => _engine.reset();

  static String _resolveUrl(String? groupTestUrl, AppConfig config) {
    final trimmed = groupTestUrl?.trim() ?? '';
    return trimmed.isEmpty ? config.delayTestUrl : trimmed;
  }
}

final proxyDelayProvider =
    NotifierProvider<ProxyDelayNotifier, ProxyDelayState>(
      ProxyDelayNotifier.new,
    );
