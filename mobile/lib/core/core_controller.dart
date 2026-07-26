/// The only way the UI talks to the tunnel.
///
/// Ports the parts of `src/main/core/manager.ts` that have an Android meaning,
/// and enforces three of the seven non-negotiables directly:
///
/// * **N1** — the transport is never declared up before the core proves
///   healthy. The Kotlin side gates `establish()` on its own checks; this side
///   additionally refuses to publish [CoreState.running] until the core's own
///   Clash API answers.
/// * **N2** — a new config is validated with `checkConfig` while the previous
///   core is still serving traffic, and only then swapped in.
/// * **N3** — a rejected config falls back to the last-known-good one
///   automatically, and the failure is reported rather than swallowed.
/// * **N4** — a conversion that produced errors stops the start. The
///   converter's refusal messages are surfaced verbatim; nothing here degrades
///   quietly to direct.
library;

import 'dart:async';
import 'dart:convert';

import 'package:aikobox_convert/aikobox_convert.dart';
import 'package:aikobox_subscription/aikobox_subscription.dart'
    show redactSecrets;

import 'app_config.dart';
import 'clash_api.dart';
import 'config_store.dart';
import 'core_channel.dart';
import 'models.dart';
import 'profile_store.dart';

/// The tunnel surface the UI is allowed to touch.
abstract class CoreController {
  /// consent → validate → establish → health-gate.
  Future<void> start();

  Future<void> stop();

  /// Switches the active profile, reloading the core when it is running.
  Future<void> reloadProfile(String profileId);

  Future<void> setMode(OutboundMode mode);

  Future<void> selectProxy(String group, String node);

  /// Milliseconds, or `null` when the probe failed.
  Future<int?> testDelay(String node);

  Future<Map<String, int>> testGroupDelay(String group);

  Future<void> closeConnection(String id);

  Future<void> closeAllConnections();
}

/// The core refused to start, and the reason is worth showing to the user.
class CoreStartException implements Exception {
  const CoreStartException(
    this.code,
    this.message, {
    this.details = const <String>[],
  });

  /// A stable code the UI maps to an l10n key.
  final String code;

  /// English fallback. Safe to display.
  final String message;

  /// The converter's or the core's own lines, verbatim (N4).
  final List<String> details;

  /// No profile is selected, so there is nothing to start.
  static const String codeNoProfile = 'E_NO_PROFILE';

  /// The profile could not be read or is not a Clash config.
  static const String codeProfileUnreadable = 'E_PROFILE_UNREADABLE';

  /// The converter refused. [details] holds its messages, unmodified.
  static const String codeConversionRefused = 'E_CONVERSION_REFUSED';

  /// `checkConfig` rejected the candidate and no last-known-good exists.
  static const String codeConfigInvalid = 'E_CONFIG_INVALID';

  /// The user declined the VPN consent dialog.
  static const String codeVpnPermissionDenied = 'E_VPN_PERMISSION_DENIED';

  /// The core came up but never became healthy.
  static const String codeHealthGateFailed = 'E_CORE_START_FAILED';

  @override
  String toString() =>
      'CoreStartException($code): $message${details.isEmpty ? '' : '\n${details.join('\n')}'}';
}

/// Builds a [ClashApi] for a given controller endpoint. Injectable for tests.
typedef ClashApiFactory =
    ClashApi Function({
      required String host,
      required int port,
      required String secret,
    });

ClashApi _defaultClashApiFactory({
  required String host,
  required int port,
  required String secret,
}) => ClashApi(host: host, port: port, secret: secret);

/// The real controller.
class AikoCoreController implements CoreController {
  AikoCoreController({
    required CoreChannel channel,
    required SingboxConfigStore configStore,
    required ProfileStore profileStore,
    required AppConfigStore appConfigStore,
    ClashApiFactory? clashApiFactory,
    this.healthGateTimeout = const Duration(seconds: 20),
    this.lastKnownGoodDelay = const Duration(seconds: 60),
  }) : _channel = channel,
       _configStore = configStore,
       _profileStore = profileStore,
       _appConfigStore = appConfigStore,
       _clashApiFactory = clashApiFactory ?? _defaultClashApiFactory {
    _channelSubscription = _channel.statusEvents().listen(
      _onChannelStatus,
      onError: (Object error) {
        _publish(
          _status.copyWith(
            state: CoreState.failed,
            error: redactSecrets(error.toString()),
          ),
        );
      },
    );
  }

  /// How long the health gate waits for the core to answer before giving up.
  /// §3.5 bounds each of its stages at 15 s; 20 s covers the whole sequence.
  final Duration healthGateTimeout;

  /// How long a config has to keep running before it is trusted as
  /// last-known-good. A config that starts and dies forty seconds later is not
  /// good, so this is deliberately not "on successful start".
  final Duration lastKnownGoodDelay;

  final CoreChannel _channel;
  final SingboxConfigStore _configStore;
  final ProfileStore _profileStore;
  final AppConfigStore _appConfigStore;
  final ClashApiFactory _clashApiFactory;

  final SerialTaskQueue _queue = SerialTaskQueue();
  final StreamController<CoreStatus> _statusController =
      StreamController<CoreStatus>.broadcast();

  StreamSubscription<CoreStatusEvent>? _channelSubscription;
  final StreamController<LogLine> _noticeController =
      StreamController<LogLine>.broadcast();
  Timer? _lastKnownGoodTimer;
  ClashApi? _api;
  String? _apiKey;
  CoreStatus _status = CoreStatus.stopped;
  List<String> _conversionWarnings = const <String>[];

  /// True while [_startLocked] owns the health gate, so a `running` event from
  /// the host does not race it into publishing the same transition twice.
  bool _startInFlight = false;

  /// Bumped on every start attempt so a late event from an abandoned attempt
  /// cannot publish a state that has already been superseded.
  int _generation = 0;

  /// Latest published status.
  CoreStatus get status => _status;

  /// Every status transition, including the initial value on subscribe.
  Stream<CoreStatus> get statusStream async* {
    yield _status;
    yield* _statusController.stream;
  }

  /// Warnings the converter raised on the last successful start.
  ///
  /// N5: nothing here is allowed to be silent. Every warning is also pushed to
  /// [noticeStream] so it lands in the log page whether or not anyone reads
  /// this getter.
  List<String> get conversionWarnings => _conversionWarnings;

  /// Notices worth showing the user that did not come from the core's own log:
  /// converter warnings, rollbacks, refusals.
  Stream<LogLine> get noticeStream => _noticeController.stream;

  void _notice(String level, String message) {
    if (_noticeController.isClosed) return;
    _noticeController.add(
      LogLine(level: level, payload: message, time: DateTime.now()),
    );
  }

  /// The Clash API client for the running core, creating it on first use.
  ///
  /// The endpoint comes from the host — it knows what the core actually bound,
  /// which is not necessarily what the config asked for.
  Future<ClashApi> api() async {
    final port = await _channel.clashApiPort();
    final secret = await _channel.clashApiSecret();
    final key = '127.0.0.1:$port:$secret';
    final existing = _api;
    if (existing != null && _apiKey == key) return existing;
    existing?.close();
    final created = _clashApiFactory(
      host: '127.0.0.1',
      port: port,
      secret: secret,
    );
    _api = created;
    _apiKey = key;
    return created;
  }

  Future<void> dispose() async {
    _lastKnownGoodTimer?.cancel();
    await _channelSubscription?.cancel();
    _api?.close();
    _api = null;
    await _noticeController.close();
    await _statusController.close();
  }

  void _publish(CoreStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  void _discardApi() {
    _api?.close();
    _api = null;
    _apiKey = null;
  }

  void _onChannelStatus(CoreStatusEvent event) {
    switch (event.state) {
      case CoreState.running:
        // A `running` event that this controller did not ask for — always-on
        // VPN, a boot-completed restart, a reconnect after process death —
        // still has to pass the Dart health gate before the UI believes it.
        if (!_startInFlight && _status.state != CoreState.running) {
          unawaited(_adoptRunningCore());
        }
      case CoreState.stopped:
        _lastKnownGoodTimer?.cancel();
        _discardApi();
        _publish(
          _status.copyWith(
            state: CoreState.stopped,
            clearError: true,
            clearStartedAt: true,
          ),
        );
      case CoreState.failed:
        _lastKnownGoodTimer?.cancel();
        _discardApi();
        _publish(
          _status.copyWith(
            state: CoreState.failed,
            error: event.error ?? 'The core stopped unexpectedly',
            clearStartedAt: true,
          ),
        );
      case CoreState.starting:
        _publish(_status.copyWith(state: CoreState.starting, clearError: true));
      case CoreState.stopping:
        _publish(_status.copyWith(state: CoreState.stopping));
    }
  }

  Future<void> _adoptRunningCore() async {
    final generation = _generation;
    final healthy = await _waitForClashApi();
    if (generation != _generation) return;
    if (!healthy) {
      _publish(
        _status.copyWith(
          state: CoreState.failed,
          error: 'The core started but never answered its control API',
          clearStartedAt: true,
        ),
      );
      return;
    }
    await _publishRunning();
  }

  Future<void> _publishRunning() async {
    String? version = _status.version;
    try {
      version = await (await api()).version();
    } catch (_) {
      try {
        version = await _channel.coreVersion();
      } catch (_) {
        // A missing version string is cosmetic; the tunnel is up.
      }
    }
    _publish(
      CoreStatus(
        state: CoreState.running,
        version: version,
        startedAt: DateTime.now(),
      ),
    );
    _armLastKnownGoodTimer();
  }

  void _armLastKnownGoodTimer() {
    _lastKnownGoodTimer?.cancel();
    final generation = _generation;
    _lastKnownGoodTimer = Timer(lastKnownGoodDelay, () {
      if (generation != _generation || _status.state != CoreState.running) {
        return;
      }
      unawaited(_configStore.markActiveGood().catchError((_) {}));
    });
  }

  /// Polls `GET /version` until the core answers or [healthGateTimeout]
  /// elapses. This is the Dart half of N1: "the service started" is not
  /// evidence that traffic can flow.
  Future<bool> _waitForClashApi() async {
    final deadline = DateTime.now().add(healthGateTimeout);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = await api();
        await client.version();
        return true;
      } catch (_) {
        attempt++;
        final backoff = Duration(
          milliseconds: (150 * attempt).clamp(150, 1000),
        );
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) break;
        await Future<void>.delayed(backoff < remaining ? backoff : remaining);
      }
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Future<void> start() => _queue.enqueue(_startLocked);

  Future<void> _startLocked() async {
    final generation = ++_generation;
    // Whether a core was already carrying traffic decides what a rejection
    // means: with one running, a bad candidate changes nothing; without one,
    // it has to be answered with the last-known-good config or with a failure.
    final wasRunning = _status.state == CoreState.running;
    final previousStatus = _status;
    _lastKnownGoodTimer?.cancel();
    _startInFlight = true;
    _publish(_status.copyWith(state: CoreState.starting, clearError: true));

    try {
      final appConfig = await _appConfigStore.read();

      // 1. Consent. Asked before any work so a refusal costs nothing.
      if (!await _channel.prepareVpn()) {
        if (!await _channel.requestVpnPermission()) {
          throw const CoreStartException(
            CoreStartException.codeVpnPermissionDenied,
            'VPN permission was not granted',
          );
        }
      }

      // 2. Convert. N4: a converter refusal stops the start, verbatim.
      final profile = await _profileStore.currentItem();
      if (profile == null) {
        throw const CoreStartException(
          CoreStartException.codeNoProfile,
          'No profile is selected',
        );
      }
      final Map<String, dynamic> clash;
      try {
        clash = await _profileStore.readClashConfig(profile.id);
      } catch (error) {
        throw CoreStartException(
          CoreStartException.codeProfileUnreadable,
          'Profile "${profile.name}" could not be read',
          details: <String>[error.toString()],
        );
      }
      final converted = convertClashToSingbox(
        clash,
        options: ConvertOptions(
          platform: 'android',
          autoRedirect: appConfig.autoRedirect,
        ),
      );
      if (converted.errors.isNotEmpty) {
        for (final message in converted.errors) {
          _notice('error', message);
        }
        throw CoreStartException(
          CoreStartException.codeConversionRefused,
          converted.errors.first,
          details: List<String>.unmodifiable(converted.errors),
        );
      }
      _conversionWarnings = List<String>.unmodifiable(converted.warnings);
      for (final message in _conversionWarnings) {
        _notice('warning', message);
      }

      // 3. Stage and validate the candidate while the old core still serves
      //    traffic (N2).
      await _configStore.writeCandidate(
        converted.config,
        runtimeProfile: encodeYaml(clash),
      );
      final candidateJson = jsonEncode(converted.config);
      final rejection = await _channel.checkConfig(candidateJson);
      if (rejection != null) {
        // The candidate is parked in the rejected slot for diagnostics. The
        // active config was never touched, so it must not also be relabelled
        // as rejected on the way out.
        await _configStore.discardCandidate();
        final refusal = CoreStartException(
          CoreStartException.codeConfigInvalid,
          'The core rejected the configuration',
          details: <String>[rejection],
        );
        if (wasRunning) {
          // The old core is still up and untouched. Nothing to roll back —
          // just say no and leave the tunnel exactly as it was.
          _notice('error', refusal.message);
          _notice('error', rejection);
          _publish(previousStatus.copyWith(error: refusal.message));
          throw refusal;
        }
        await _fallBackToLastKnownGood(
          generation,
          because: refusal,
          retainActiveAsRejected: false,
        );
        return;
      }

      // 4. Swap, then establish.
      await _configStore.promoteCandidate();
      await _channel.start(
        candidateJson,
        includePackages: appConfig.includePackages,
        excludePackages: appConfig.excludePackages,
      );

      // 5. Health gate (N1).
      if (!await _waitForClashApi()) {
        await _fallBackToLastKnownGood(
          generation,
          because: const CoreStartException(
            CoreStartException.codeHealthGateFailed,
            'The core started but never answered its control API',
          ),
        );
        return;
      }

      if (generation != _generation) return;
      await _publishRunning();
    } on CoreStartException catch (error) {
      _publishFailure(error.message);
      rethrow;
    } on AikoCoreException catch (error) {
      _publishFailure(error.message);
      rethrow;
    } catch (error) {
      // Untyped: could be anything the stores threw, so it is treated as
      // hostile before it reaches CoreStatus.error, which the UI renders (N7).
      // The two typed branches above are already-redacted messages.
      _publishFailure(redactSecrets(error.toString()));
      rethrow;
    } finally {
      _startInFlight = false;
    }
  }

  /// Records a failed start without lying about the tunnel.
  ///
  /// A rollback that succeeded leaves traffic flowing on the previous config:
  /// the start failed, but the state is [CoreState.running] with an error
  /// attached, not [CoreState.failed].
  void _publishFailure(String message) {
    if (_status.state == CoreState.running) {
      _publish(_status.copyWith(error: message));
      return;
    }
    _publish(
      _status.copyWith(
        state: CoreState.failed,
        error: message,
        clearStartedAt: true,
      ),
    );
  }

  /// N3. Restores the last-known-good config and starts it; if there is none,
  /// or it also fails, the original failure is what the user hears about.
  ///
  /// [retainActiveAsRejected] is false when the active config was never
  /// actually run — labelling it "rejected" would be a lie, and it would
  /// overwrite the candidate that genuinely was rejected.
  Future<void> _fallBackToLastKnownGood(
    int generation, {
    required CoreStartException because,
    bool retainActiveAsRejected = true,
  }) async {
    final restored = await _configStore.restoreLastGood(
      retainActiveAsRejected: retainActiveAsRejected,
    );
    if (restored == null) {
      await _stopQuietly();
      throw because;
    }

    try {
      final appConfig = await _appConfigStore.read();
      await _channel.start(
        jsonEncode(restored.config),
        includePackages: appConfig.includePackages,
        excludePackages: appConfig.excludePackages,
      );
      if (!await _waitForClashApi()) {
        await _stopQuietly();
        throw because;
      }
    } on CoreStartException {
      rethrow;
    } catch (_) {
      await _stopQuietly();
      throw because;
    }

    if (generation != _generation) return;
    await _publishRunning();
    // The tunnel is up, but on the *previous* config — the user has to be told
    // their new one was thrown away, so the original failure still propagates.
    _notice('error', because.message);
    for (final detail in because.details) {
      _notice('error', detail);
    }
    _publish(_status.copyWith(error: because.message));
    throw because;
  }

  Future<void> _stopQuietly() async {
    try {
      await _channel.stop();
    } catch (_) {
      // Already down, or the host is gone. Either way we are stopping.
    }
    _discardApi();
    _publish(const CoreStatus(state: CoreState.stopped));
  }

  @override
  Future<void> stop() => _queue.enqueue(() async {
    _generation++;
    _lastKnownGoodTimer?.cancel();
    _publish(_status.copyWith(state: CoreState.stopping));
    try {
      await _channel.stop();
    } finally {
      _discardApi();
      _publish(CoreStatus(state: CoreState.stopped, version: _status.version));
    }
  });

  @override
  Future<void> reloadProfile(String profileId) async {
    await _profileStore.setCurrent(profileId);
    if (_status.state == CoreState.stopped ||
        _status.state == CoreState.failed) {
      return;
    }
    // The same pipeline: the candidate is validated before the running core is
    // touched, so a bad new profile cannot take the tunnel down (N2).
    await start();
  }

  // -------------------------------------------------------------------------
  // Runtime controls
  // -------------------------------------------------------------------------

  @override
  Future<void> setMode(OutboundMode mode) async {
    final client = await api();
    await client.patchConfigs(<String, dynamic>{'mode': mode.wireName});
    final appConfig = await _appConfigStore.read();
    if (appConfig.autoCloseConnection) {
      try {
        await client.closeAllConnections();
      } catch (_) {
        // Stale connections outliving a mode switch is cosmetic.
      }
    }
  }

  /// The mode the core is actually in, read from `GET /configs`.
  Future<OutboundMode> currentMode() async {
    final configs = await (await api()).configs();
    return OutboundMode.fromWire(configs['mode']);
  }

  @override
  Future<void> selectProxy(String group, String node) async {
    final client = await api();
    await client.selectProxy(group, node);
    final appConfig = await _appConfigStore.read();
    if (appConfig.autoCloseConnection) {
      try {
        await client.closeAllConnections();
      } catch (_) {
        // Same: not worth failing the selection over.
      }
    }
  }

  @override
  Future<int?> testDelay(String node) async {
    final appConfig = await _appConfigStore.read();
    return (await api()).proxyDelay(
      node,
      url: appConfig.delayTestUrl,
      timeoutMs: appConfig.delayTestTimeout,
    );
  }

  @override
  Future<Map<String, int>> testGroupDelay(String group) async {
    final appConfig = await _appConfigStore.read();
    final client = await api();
    try {
      return await client.groupDelay(
        group,
        url: appConfig.delayTestUrl,
        timeoutMs: appConfig.delayTestTimeout,
      );
    } on ClashApiException catch (error) {
      if (!error.isNotFound) rethrow;
    }

    // Some builds of the clash_api handler do not expose /group/<name>/delay.
    // Sweeping the members individually is slower but produces the same table,
    // which is better than an empty proxies page.
    final snapshot = await client.proxies();
    final members = snapshot.groupNamed(group)?.all ?? const <String>[];
    return _sweepDelays(
      client,
      members.where((name) => snapshot.groupNamed(name) == null),
      url: appConfig.delayTestUrl,
      timeoutMs: appConfig.delayTestTimeout,
      concurrency: appConfig.delayTestConcurrency,
    );
  }

  static Future<Map<String, int>> _sweepDelays(
    ClashApi client,
    Iterable<String> names, {
    required String url,
    required int timeoutMs,
    required int concurrency,
  }) async {
    final pending = names.toList(growable: false);
    final results = <String, int>{};
    final lanes = concurrency.clamp(1, 64);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= pending.length) return;
        final name = pending[index];
        try {
          results[name] =
              await client.proxyDelay(name, url: url, timeoutMs: timeoutMs) ??
              0;
        } catch (_) {
          results[name] = 0;
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (var lane = 0; lane < lanes && lane < pending.length; lane++)
        worker(),
    ]);
    return results;
  }

  @override
  Future<void> closeConnection(String id) async =>
      (await api()).closeConnection(id);

  @override
  Future<void> closeAllConnections() async =>
      (await api()).closeAllConnections();
}
