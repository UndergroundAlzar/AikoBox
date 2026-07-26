/// Dashboard-local state.
///
/// Everything here is derived from `core/providers.dart`; nothing in this file
/// talks to the platform channel or the Clash API directly. Three things the
/// core layer deliberately does not provide, because only the dashboard needs
/// them, live here:
///
/// * a rolling traffic window for the sparkline,
/// * the network-detection latency probe (a port of the desktop's
///   `measureLatency` and its allow-listed target set),
/// * a read-only summary of the active profile's `dns:` / `sniffer:` /
///   `rules:` sections, which is the only truthful source for those cards when
///   the core is not running.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/providers.dart';

// ---------------------------------------------------------------------------
// Traffic history
// ---------------------------------------------------------------------------

/// How many one-second samples the network-speed sparkline keeps.
///
/// Sixty is one minute of history, which is what the card's width can resolve
/// without the line turning into noise.
const int kTrafficHistoryLength = 60;

/// A rolling window of `/traffic` samples, oldest first.
///
/// Reset whenever the core leaves [CoreState.running]: a chart that carries
/// the previous session's peaks across a restart is a lie about the current
/// one.
class TrafficHistoryNotifier extends Notifier<List<TrafficPoint>> {
  @override
  List<TrafficPoint> build() {
    ref.listen<AsyncValue<TrafficPoint>>(trafficProvider, (
      AsyncValue<TrafficPoint>? previous,
      AsyncValue<TrafficPoint> next,
    ) {
      final TrafficPoint? point = next.value;
      if (point == null || point == previous?.value) return;
      _append(point);
    });

    ref.listen<CoreStatus>(coreStatusProvider, (
      CoreStatus? previous,
      CoreStatus next,
    ) {
      if (!next.isRunning) clear();
    });

    return const <TrafficPoint>[];
  }

  void _append(TrafficPoint point) {
    if (!ref.mounted) return;
    final List<TrafficPoint> next = <TrafficPoint>[...state, point];
    final int overflow = next.length - kTrafficHistoryLength;
    state = List<TrafficPoint>.unmodifiable(
      overflow > 0 ? next.sublist(overflow) : next,
    );
  }

  /// Drops the window. Called on every stop, and by the pull-to-refresh.
  void clear() {
    if (!ref.mounted || state.isEmpty) return;
    state = const <TrafficPoint>[];
  }
}

final NotifierProvider<TrafficHistoryNotifier, List<TrafficPoint>>
trafficHistoryProvider =
    NotifierProvider<TrafficHistoryNotifier, List<TrafficPoint>>(
      TrafficHistoryNotifier.new,
    );

// ---------------------------------------------------------------------------
// Core version
// ---------------------------------------------------------------------------

/// The sing-box version string.
///
/// Prefers what the running core reported over its own API, and falls back to
/// `coreVersion()` on the platform channel so the card is not blank while the
/// tunnel is down — the linked libbox has a version whether or not it is
/// currently serving traffic.
final FutureProvider<String> coreVersionProvider = FutureProvider<String>((
  Ref ref,
) async {
  final String? reported = ref.watch(
    coreStatusProvider.select((CoreStatus status) => status.version),
  );
  if (reported != null && reported.isNotEmpty) return reported;
  return ref.watch(coreChannelProvider).coreVersion();
});

// ---------------------------------------------------------------------------
// Network detection
// ---------------------------------------------------------------------------

/// One endpoint the network-detection card probes.
@immutable
class LatencyTarget {
  const LatencyTarget({required this.name, required this.url});

  /// Display name. Not localised — these are proper nouns and host names.
  final String name;

  /// An absolute `http:` or `https:` URL.
  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LatencyTarget && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);

  @override
  String toString() => 'LatencyTarget($name, $url)';
}

/// The desktop's `DEFAULT_LATENCY_TARGETS`, unchanged.
const List<LatencyTarget> kDefaultLatencyTargets = <LatencyTarget>[
  LatencyTarget(name: 'Google', url: 'https://www.google.com/generate_204'),
  LatencyTarget(
    name: 'Cloudflare',
    url: 'https://www.cloudflare.com/cdn-cgi/trace',
  ),
  LatencyTarget(name: 'GitHub', url: 'https://github.com/'),
];

/// One probe result.
@immutable
class LatencyProbeResult {
  const LatencyProbeResult({
    required this.target,
    this.delayMs,
    this.pending = false,
  });

  /// A probe that has been started but not yet answered.
  const LatencyProbeResult.pending(LatencyTarget target)
    : this(target: target, pending: true);

  final LatencyTarget target;

  /// Round-trip milliseconds, or `null` when the probe failed or timed out.
  final int? delayMs;

  /// Measurement in flight.
  final bool pending;

  bool get failed => !pending && delayMs == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LatencyProbeResult &&
          other.target == target &&
          other.delayMs == delayMs &&
          other.pending == pending;

  @override
  int get hashCode => Object.hash(target, delayMs, pending);
}

/// The HTTP client the latency probe uses. Overridden in tests.
final Provider<http.Client> latencyHttpClientProvider = Provider<http.Client>((
  Ref ref,
) {
  final http.Client client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Normalises a user- or config-supplied address the way the desktop's
/// `normalizeLatencyUrl` does: a bare host gains `https://`, and anything that
/// is not http(s) is rejected outright rather than probed.
String? normalizeLatencyUrl(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final bool hasScheme = RegExp(
    r'^[a-z][a-z\d+\-.]*://',
    caseSensitive: false,
  ).hasMatch(trimmed);
  final Uri? uri = Uri.tryParse(hasScheme ? trimmed : 'https://$trimmed');
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.toString();
}

/// The endpoints the card probes: the three defaults plus the configured
/// delay-test URL, which is a target the user has actually chosen.
final Provider<List<LatencyTarget>> latencyTargetsProvider =
    Provider<List<LatencyTarget>>((Ref ref) {
      final String configured = ref.watch(
        appConfigProvider.select((AppConfig config) => config.delayTestUrl),
      );

      final List<LatencyTarget> targets = <LatencyTarget>[];
      final Set<String> seen = <String>{};

      void add(LatencyTarget target) {
        final String? url = normalizeLatencyUrl(target.url);
        if (url == null || !seen.add(url)) return;
        targets.add(LatencyTarget(name: target.name, url: url));
      }

      for (final LatencyTarget target in kDefaultLatencyTargets) {
        add(target);
      }
      final String? extra = normalizeLatencyUrl(configured);
      if (extra != null) {
        add(LatencyTarget(name: Uri.parse(extra).host, url: extra));
      }
      return List<LatencyTarget>.unmodifiable(targets);
    });

/// Runs the latency probes and holds their results.
///
/// Port of `measureLatency` in `src/main/utils/ipc.ts`: one GET per target,
/// bounded by the configured delay-test timeout, and a failure is reported as
/// "no reading" rather than thrown. Only the response headers are read — the
/// body is dropped without being downloaded, so probing a full web page costs
/// no more than probing a 204 endpoint.
class NetworkLatencyNotifier extends AsyncNotifier<List<LatencyProbeResult>> {
  @override
  Future<List<LatencyProbeResult>> build() async {
    final List<LatencyTarget> targets = ref.watch(latencyTargetsProvider);
    return _probeAll(targets);
  }

  Duration get _timeout => Duration(
    milliseconds: ref
        .read(appConfigProvider.select((AppConfig c) => c.delayTestTimeout))
        .clamp(1000, 15000),
  );

  /// Re-probes every target, publishing a pending row per target first so each
  /// one can show its own spinner.
  Future<void> refresh() async {
    final List<LatencyTarget> targets = ref.read(latencyTargetsProvider);
    state = AsyncValue<List<LatencyProbeResult>>.data(<LatencyProbeResult>[
      for (final LatencyTarget target in targets)
        LatencyProbeResult.pending(target),
    ]);
    final List<LatencyProbeResult> results = await _probeAll(targets);
    if (!ref.mounted) return;
    state = AsyncValue<List<LatencyProbeResult>>.data(results);
  }

  Future<List<LatencyProbeResult>> _probeAll(
    List<LatencyTarget> targets,
  ) async {
    final http.Client client = ref.read(latencyHttpClientProvider);
    final Duration timeout = _timeout;
    return Future.wait<LatencyProbeResult>(<Future<LatencyProbeResult>>[
      for (final LatencyTarget target in targets)
        probeLatency(client, target, timeout),
    ]);
  }
}

/// Measures time-to-response for one target. Never throws.
///
/// A 4xx still proves the network path works end to end, so it counts as a
/// reading; only a transport failure, a timeout or a 5xx counts as "no
/// answer".
Future<LatencyProbeResult> probeLatency(
  http.Client client,
  LatencyTarget target,
  Duration timeout,
) async {
  final Uri? uri = Uri.tryParse(target.url);
  if (uri == null) return LatencyProbeResult(target: target);

  final Stopwatch watch = Stopwatch()..start();
  try {
    final http.StreamedResponse response = await client
        .send(http.Request('GET', uri))
        .timeout(timeout);
    final int elapsed = watch.elapsedMilliseconds;
    // Release the socket without downloading the body.
    await response.stream.listen(null).cancel();
    if (response.statusCode >= 500) return LatencyProbeResult(target: target);
    return LatencyProbeResult(target: target, delayMs: elapsed);
  } catch (_) {
    return LatencyProbeResult(target: target);
  }
}

final AsyncNotifierProvider<NetworkLatencyNotifier, List<LatencyProbeResult>>
networkLatencyProvider =
    AsyncNotifierProvider<NetworkLatencyNotifier, List<LatencyProbeResult>>(
      NetworkLatencyNotifier.new,
    );

// ---------------------------------------------------------------------------
// Active profile summary
// ---------------------------------------------------------------------------

/// What the active profile declares about DNS, sniffing and routing.
///
/// The desktop's DNS and sniff sider cards were switches over `controlDns` /
/// `controlSniff` — AikoBox's own overrides of those sections. That pair of
/// settings is not in the Android `AppConfig`, so these cards report what the
/// profile itself asks for instead of pretending to toggle something.
@immutable
class ProfileRuntimeSummary {
  const ProfileRuntimeSummary({
    this.hasProfile = false,
    this.dnsEnabled = false,
    this.dnsMode = '',
    this.dnsServerCount = 0,
    this.snifferEnabled = false,
    this.sniffProtocols = const <String>[],
    this.ruleCount = 0,
    this.proxyCount = 0,
    this.groupCount = 0,
  });

  /// No profile is selected.
  static const ProfileRuntimeSummary none = ProfileRuntimeSummary();

  factory ProfileRuntimeSummary.fromClash(Map<String, dynamic> clash) {
    final Map<String, dynamic> dns = _mapAt(clash['dns']);
    final Map<String, dynamic> sniffer = _mapAt(clash['sniffer']);
    final Map<String, dynamic> sniff = _mapAt(sniffer['sniff']);

    return ProfileRuntimeSummary(
      hasProfile: true,
      dnsEnabled: _boolAt(dns['enable']),
      dnsMode: dns['enhanced-mode']?.toString().trim() ?? '',
      dnsServerCount:
          _listAt(dns['nameserver']).length + _listAt(dns['fallback']).length,
      snifferEnabled: _boolAt(sniffer['enable']),
      sniffProtocols: List<String>.unmodifiable(
        sniff.keys.map((String key) => key.toUpperCase()).toList()..sort(),
      ),
      ruleCount: _listAt(clash['rules']).length,
      proxyCount: _listAt(clash['proxies']).length,
      groupCount: _listAt(clash['proxy-groups']).length,
    );
  }

  final bool hasProfile;
  final bool dnsEnabled;

  /// `fake-ip`, `redir-host`, `normal`, or empty when unspecified.
  final String dnsMode;
  final int dnsServerCount;
  final bool snifferEnabled;

  /// Upper-cased protocol names, e.g. `HTTP`, `TLS`, `QUIC`.
  final List<String> sniffProtocols;
  final int ruleCount;
  final int proxyCount;
  final int groupCount;

  static Map<String, dynamic> _mapAt(Object? value) => value is Map
      ? <String, dynamic>{
          for (final MapEntry<Object?, Object?> entry in value.entries)
            entry.key.toString(): entry.value,
        }
      : const <String, dynamic>{};

  static List<Object?> _listAt(Object? value) =>
      value is List ? value : const <Object?>[];

  static bool _boolAt(Object? value) {
    if (value is bool) return value;
    if (value is String) return value.trim().toLowerCase() == 'true';
    return false;
  }
}

/// Reads and parses the active profile once, lazily.
///
/// Only evaluated when a card that needs it is actually visible, so a user who
/// hides the DNS and sniff cards never pays for the YAML parse.
final FutureProvider<ProfileRuntimeSummary> profileRuntimeSummaryProvider =
    FutureProvider<ProfileRuntimeSummary>((Ref ref) async {
      final ProfileItem? profile = ref.watch(currentProfileProvider);
      if (profile == null) return ProfileRuntimeSummary.none;
      final ProfileStore store = await ref.watch(profileStoreProvider.future);
      final Map<String, dynamic> clash = await store.readClashConfig(
        profile.id,
      );
      return ProfileRuntimeSummary.fromClash(clash);
    });
