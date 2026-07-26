import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main entry point.
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const LatencyTarget _target = LatencyTarget(
  name: 'Google',
  url: 'https://www.google.com/generate_204',
);

void main() {
  group('normalizeLatencyUrl', () {
    test('adds https to a bare host', () {
      expect(normalizeLatencyUrl('example.com'), 'https://example.com');
    });

    test('keeps an explicit scheme', () {
      expect(
        normalizeLatencyUrl('http://example.com/trace'),
        'http://example.com/trace',
      );
    });

    test('rejects anything that is not http(s)', () {
      expect(normalizeLatencyUrl('ftp://example.com'), isNull);
      expect(normalizeLatencyUrl('ss://abcd'), isNull);
      expect(normalizeLatencyUrl('   '), isNull);
      expect(normalizeLatencyUrl(''), isNull);
    });
  });

  group('probeLatency', () {
    test('a 204 counts as a reading', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('', 204),
      );
      final LatencyProbeResult result = await probeLatency(
        client,
        _target,
        const Duration(seconds: 5),
      );
      expect(result.delayMs, isNotNull);
      expect(result.delayMs, greaterThanOrEqualTo(0));
      expect(result.failed, isFalse);
      expect(result.pending, isFalse);
    });

    test('a 404 still proves the path works', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('nope', 404),
      );
      final LatencyProbeResult result = await probeLatency(
        client,
        _target,
        const Duration(seconds: 5),
      );
      expect(result.delayMs, isNotNull);
    });

    test('a 5xx is not a reading', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response('', 503),
      );
      final LatencyProbeResult result = await probeLatency(
        client,
        _target,
        const Duration(seconds: 5),
      );
      expect(result.delayMs, isNull);
      expect(result.failed, isTrue);
    });

    test('a transport failure is reported, never thrown', () async {
      final MockClient client = MockClient(
        (http.Request request) async => throw http.ClientException('offline'),
      );
      final LatencyProbeResult result = await probeLatency(
        client,
        _target,
        const Duration(seconds: 5),
      );
      expect(result.delayMs, isNull);
    });

    test('a slow endpoint is cut off at the timeout', () async {
      final MockClient client = MockClient((http.Request request) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response('', 204);
      });
      final LatencyProbeResult result = await probeLatency(
        client,
        _target,
        const Duration(milliseconds: 30),
      );
      expect(result.delayMs, isNull);
    });

    test('an unparseable target is not probed', () async {
      var calls = 0;
      final MockClient client = MockClient((http.Request request) async {
        calls++;
        return http.Response('', 204);
      });
      final LatencyProbeResult result = await probeLatency(
        client,
        const LatencyTarget(name: 'bad', url: '::::'),
        const Duration(seconds: 5),
      );
      expect(result.delayMs, isNull);
      expect(calls, 0);
    });
  });

  group('latencyTargetsProvider', () {
    ProviderContainer containerFor(AppConfig config) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appConfigProvider.overrideWith(() => _StaticAppConfig(config)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('carries the desktop defaults', () {
      final List<LatencyTarget> targets = containerFor(
        AppConfig.defaults,
      ).read(latencyTargetsProvider);
      expect(
        targets.map((LatencyTarget t) => t.name).take(3),
        kDefaultLatencyTargets.map((LatencyTarget t) => t.name),
      );
      // The stock delay-test URL is a fourth, distinct target.
      expect(targets.length, kDefaultLatencyTargets.length + 1);
      expect(targets.last.url, AppConfig.defaults.delayTestUrl);
    });

    test('adds the configured delay-test URL as a target', () {
      final List<LatencyTarget> targets = containerFor(
        AppConfig.defaults.copyWith(
          delayTestUrl: 'https://cp.cloudflare.com/generate_204',
        ),
      ).read(latencyTargetsProvider);
      expect(
        targets.map((LatencyTarget t) => t.url),
        contains('https://cp.cloudflare.com/generate_204'),
      );
      expect(targets.length, kDefaultLatencyTargets.length + 1);
    });

    test('a delay-test URL that is already a default is not duplicated', () {
      final List<LatencyTarget> targets = containerFor(
        AppConfig.defaults.copyWith(
          delayTestUrl: kDefaultLatencyTargets.first.url,
        ),
      ).read(latencyTargetsProvider);
      expect(targets.length, kDefaultLatencyTargets.length);
      expect(
        targets.map((LatencyTarget t) => t.url).toSet().length,
        targets.length,
      );
    });

    test('a non-http delay-test URL is dropped, not probed', () {
      final List<LatencyTarget> targets = containerFor(
        AppConfig.defaults.copyWith(delayTestUrl: 'ftp://example.com/probe'),
      ).read(latencyTargetsProvider);
      expect(targets.length, kDefaultLatencyTargets.length);
    });
  });
}

class _StaticAppConfig extends AppConfigNotifier {
  _StaticAppConfig(this._value);
  final AppConfig _value;

  @override
  AppConfig build() => _value;
}
