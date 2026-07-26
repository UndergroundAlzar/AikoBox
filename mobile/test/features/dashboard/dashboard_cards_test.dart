import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/cards/connection_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/core_info_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/dns_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/network_detection_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/network_speed_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/outbound_mode_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/profile_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/proxy_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/rule_card.dart';
import 'package:aikobox_mobile/features/dashboard/cards/traffic_usage_card.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

CoreStatus _running() => const CoreStatus(state: CoreState.running);

TrafficPoint _point(int up, int down) =>
    TrafficPoint(up: up, down: down, at: DateTime(2026));

void main() {
  setUp(primeEnglish);
  tearDown(AikoL10n.resetForTests);

  group('network speed card', () {
    testWidgets('says it is idle before any sample arrives', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: NetworkSpeedCard()),
        harness: harness,
      );

      expect(find.text('Idle'), findsOneWidget);
      expect(find.byType(Sparkline), findsNothing);
    });

    testWidgets('renders both rates and a two-series sparkline', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        traffic: <TrafficPoint>[
          _point(0, 0),
          _point(1024, 2048),
          _point(2048, 4096),
        ],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: NetworkSpeedCard()),
        harness: harness,
      );

      expect(find.text('2.00 KB/s'), findsOneWidget);
      expect(find.text('4.00 KB/s'), findsOneWidget);
      final Sparkline sparkline = tester.widget<Sparkline>(
        find.byType(Sparkline),
      );
      expect(sparkline.series, hasLength(2));
      expect(sparkline.series.first.values, hasLength(3));
    });
  });

  group('outbound mode card', () {
    testWidgets('the live mode is the selected radio', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        mode: OutboundMode.global,
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: OutboundModeCard()),
        harness: harness,
      );

      expect(find.text('Rule'), findsOneWidget);
      expect(find.text('Global'), findsOneWidget);
      expect(find.text('Direct'), findsOneWidget);

      final RadioGroup<OutboundMode> group = tester
          .widget<RadioGroup<OutboundMode>>(
            find.byType(RadioGroup<OutboundMode>),
          );
      expect(group.groupValue, OutboundMode.global);
    });

    testWidgets('tapping a mode asks the notifier to switch', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(status: _running());
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: OutboundModeCard()),
        harness: harness,
      );

      await tester.tap(find.text('Direct'));
      await tester.pump();

      expect(harness.modeSelections, <OutboundMode>[OutboundMode.direct]);
    });

    testWidgets('the radios are inert while the core is down', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: OutboundModeCard()),
        harness: harness,
      );

      await tester.tap(find.text('Direct'));
      await tester.pump();

      expect(harness.modeSelections, isEmpty);
    });
  });

  group('traffic usage card', () {
    testWidgets('shows cumulative totals and a provider quota', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        totals: (up: 1024 * 1024, down: 3 * 1024 * 1024),
        proxyProviders: <String, ProviderInfo>{
          'airport': ProviderInfo(
            name: 'airport',
            type: 'Proxy',
            vehicleType: 'HTTP',
            subscription: const SubscriptionUsage(
              upload: 512,
              download: 512,
              total: 4096,
              expire: 0,
            ),
          ),
        },
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: TrafficUsageCard()),
        harness: harness,
      );

      expect(find.text('1.00 MB'), findsOneWidget);
      expect(find.text('3.00 MB'), findsOneWidget);
      expect(find.text('airport'), findsOneWidget);
      expect(find.text('1.00 KB/4.00 KB'), findsOneWidget);
      // No expiry reported -> "Never Expire", not a fabricated date.
      expect(find.text('Never Expire'), findsOneWidget);
    });
  });

  group('core info card', () {
    testWidgets('reports the version and memory in use', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        memory: MemoryPoint(
          inuse: 30 * 1024 * 1024,
          oslimit: 0,
          at: DateTime(2026),
        ),
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: CoreInfoCard()),
        harness: harness,
      );

      expect(find.text('sing-box 1.13.0-aiko'), findsOneWidget);
      expect(find.text('30.00 MB'), findsOneWidget);
    });
  });

  group('profile card', () {
    testWidgets('an empty install points at importing a subscription', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: DashboardProfileCard()),
        harness: harness,
      );

      expect(find.text('No profile selected'), findsOneWidget);
      expect(find.text('Import a subscription'), findsOneWidget);
    });

    testWidgets('a remote profile shows its quota, expiry and refresh', (
      WidgetTester tester,
    ) async {
      final DateTime expiry = DateTime.now().add(const Duration(days: 10));
      final ProfileItem profile = ProfileItem(
        id: 'p1',
        type: 'remote',
        name: 'Airport HK',
        url: 'https://example.com/sub',
        extra: SubscriptionUsage(
          upload: 1024,
          download: 1024,
          total: 8192,
          expire: expiry.millisecondsSinceEpoch ~/ 1000,
        ),
      );
      final DashboardHarness harness = DashboardHarness(
        profile: profile,
        profiles: <ProfileItem>[profile],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: DashboardProfileCard()),
        harness: harness,
      );

      expect(find.text('Airport HK'), findsOneWidget);
      expect(find.text('Remote'), findsOneWidget);
      expect(find.text('2.00 KB/8.00 KB'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();
      expect(harness.profileUpdates, <String>['p1']);
    });

    testWidgets('a local profile offers no subscription refresh', (
      WidgetTester tester,
    ) async {
      const ProfileItem profile = ProfileItem(
        id: 'p2',
        type: 'local',
        name: 'Pasted',
      );
      final DashboardHarness harness = DashboardHarness(
        profile: profile,
        profiles: const <ProfileItem>[profile],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: DashboardProfileCard()),
        harness: harness,
      );

      expect(find.text('Local'), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    });
  });

  group('proxy card', () {
    testWidgets('shows the selectable group and its current node', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        proxies: const ProxiesSnapshot(
          groups: <ProxyGroup>[
            ProxyGroup(
              name: 'Auto',
              type: 'URLTest',
              now: 'HK 01',
              all: <String>['HK 01'],
            ),
            ProxyGroup(
              name: 'Proxy',
              type: 'Selector',
              now: 'HK 02',
              all: <String>['HK 01', 'HK 02'],
            ),
          ],
          nodes: <String, ProxyNode>{
            'HK 01': ProxyNode(name: 'HK 01', type: 'Vmess', delay: 88),
            'HK 02': ProxyNode(name: 'HK 02', type: 'Vmess', delay: 240),
          },
        ),
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: ProxySelectionCard()),
        harness: harness,
      );

      // The Selector wins over the URLTest — it is the one a user can change.
      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('HK 02'), findsOneWidget);
      expect(find.text('240 ms'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('tapping asks the shell for the proxies page', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(status: _running());
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: ProxySelectionCard()),
        harness: harness,
      );

      await tester.tap(find.byType(ProxySelectionCard));
      await tester.pump();

      expect(harness.opened, <DashboardDestination>[
        DashboardDestination.proxies,
      ]);
    });
  });

  group('connection and rule cards', () {
    testWidgets('connection count comes from the live list', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        status: _running(),
        connections: <ConnectionInfo>[
          ConnectionInfo(
            id: 'a',
            host: 'example.com:443',
            network: 'tcp',
            rule: 'Match',
            chains: const <String>['Proxy'],
            upload: 0,
            download: 0,
            uploadSpeed: 0,
            downloadSpeed: 0,
            start: DateTime(2026),
          ),
        ],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: ConnectionCountCard()),
        harness: harness,
      );

      expect(find.text('1'), findsOneWidget);
      expect(find.text('1 connection'), findsOneWidget);
    });

    testWidgets('the rule count falls back to the profile when stopped', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        summary: const ProfileRuntimeSummary(hasProfile: true, ruleCount: 42),
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: RuleCountCard()),
        harness: harness,
      );

      expect(find.text('42'), findsOneWidget);
      expect(find.text('The core is not running'), findsOneWidget);
    });
  });

  group('dns card', () {
    testWidgets('reports what the profile declares', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        summary: const ProfileRuntimeSummary(
          hasProfile: true,
          dnsEnabled: true,
          dnsMode: 'fake-ip',
          dnsServerCount: 3,
        ),
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: DnsCard()),
        harness: harness,
      );

      expect(find.text('Enabled'), findsOneWidget);
      expect(find.text('Fake IP'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('with no profile it shows a dash, not a guess', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness();
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: DnsCard()),
        harness: harness,
      );

      expect(find.text(kDashboardNoValue), findsOneWidget);
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Disabled'), findsNothing);
    });
  });

  group('network detection card', () {
    testWidgets('renders one chip per target and an average', (
      WidgetTester tester,
    ) async {
      final DashboardHarness harness = DashboardHarness(
        latency: const <LatencyProbeResult>[
          LatencyProbeResult(
            target: LatencyTarget(name: 'Google', url: 'https://g/'),
            delayMs: 100,
          ),
          LatencyProbeResult(
            target: LatencyTarget(name: 'Cloudflare', url: 'https://c/'),
            delayMs: 200,
          ),
          LatencyProbeResult(
            target: LatencyTarget(name: 'GitHub', url: 'https://h/'),
          ),
        ],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: NetworkDetectionCard()),
        harness: harness,
      );

      expect(find.byType(DelayChip), findsNWidgets(3));
      expect(find.text('100 ms'), findsOneWidget);
      expect(find.text('200 ms'), findsOneWidget);
      // The failed probe is averaged out, not counted as zero.
      expect(find.text('150 ms'), findsOneWidget);
    });

    testWidgets('the refresh action re-probes', (WidgetTester tester) async {
      final DashboardHarness harness = DashboardHarness(
        latency: const <LatencyProbeResult>[
          LatencyProbeResult(
            target: LatencyTarget(name: 'Google', url: 'https://g/'),
            delayMs: 100,
          ),
        ],
      );
      await pumpDashboardWidget(
        tester,
        const Scaffold(body: NetworkDetectionCard()),
        harness: harness,
      );

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();

      expect(harness.latencyRefreshes, hasLength(1));
    });
  });
}
