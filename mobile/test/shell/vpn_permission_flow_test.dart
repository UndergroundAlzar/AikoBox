import 'package:aikobox_mobile/core/core_channel.dart';
import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/shell/shell_host_channel.dart';
import 'package:aikobox_mobile/features/shell/vpn_permission_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shell_harness.dart';

const Map<String, String> _strings = <String, String>{
  'vpn.permission.title': 'VPN permission required',
  'vpn.permission.message': 'AikoBox needs to create a VPN connection.',
  'vpn.permission.openSettings': 'Open system VPN settings',
  'vpn.permission.denied.title': 'VPN permission denied',
  'vpn.permission.denied.message': 'Nothing was started.',
  'notification.permission.title': 'Allow notifications',
  'notification.permission.message': 'Android requires a notification.',
  'notification.permission.denied': 'Notifications are blocked.',
  'notification.settings': 'Notification settings',
  'common.continue': 'Continue',
  'common.cancel': 'Cancel',
  'common.allow': 'Allow',
  'common.notNow': 'Not now',
  'common.ok': 'OK',
  'common.dismiss': 'Dismiss',
};

/// Records what the flow asked the tunnel host for.
class FakeCoreChannel implements CoreChannel {
  FakeCoreChannel({
    this.prepared = true,
    this.consentGranted = true,
    this.prepareThrows,
  });

  bool prepared;
  bool consentGranted;
  AikoCoreException? prepareThrows;

  int prepareCalls = 0;
  int requestCalls = 0;

  @override
  Future<bool> prepareVpn() async {
    prepareCalls++;
    final AikoCoreException? failure = prepareThrows;
    if (failure != null) throw failure;
    return prepared;
  }

  @override
  Future<bool> requestVpnPermission() async {
    requestCalls++;
    return consentGranted;
  }

  @override
  Future<String?> checkConfig(String json) async => null;

  @override
  Future<int> clashApiPort() async => 9090;

  @override
  Future<String> clashApiSecret() async => '';

  @override
  Future<String> coreVersion() async => 'test';

  @override
  Future<List<InstalledApp>> installedApps() async => const <InstalledApp>[];

  @override
  Stream<LogLine> logEvents() => const Stream<LogLine>.empty();

  @override
  Stream<CoreStatusEvent> statusEvents() =>
      const Stream<CoreStatusEvent>.empty();

  @override
  Future<void> start(
    String configJson, {
    List<String> includePackages = const <String>[],
    List<String> excludePackages = const <String>[],
  }) async {}

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel hostChannel = MethodChannel(ShellHostChannel.channelName);
  final List<String> hostCalls = <String>[];

  void mockHost(Map<String, Object?> responses) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
          hostCalls.add(call.method);
          return responses[call.method];
        });
  }

  /// Stands in for a build whose Kotlin side does not implement
  /// `aikobox/shell`.
  ///
  /// A handler is installed rather than left absent on purpose:
  /// `testWidgets` runs inside `FakeAsync`, so a platform message that falls
  /// through to the real messenger never gets its reply delivered and the
  /// future hangs. Throwing `MissingPluginException` from a mock handler
  /// produces exactly the failure a channel-less host produces, inside the
  /// fake clock.
  void mockHostMissing() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
          hostCalls.add(call.method);
          throw MissingPluginException('no aikobox/shell in this build');
        });
  }

  setUp(() {
    hostCalls.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    mockHostMissing();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, null);
  });

  /// Mounts a page and hands its context to [run], pumping between steps.
  Future<TunnelPermissionResult> drive(
    WidgetTester tester,
    VpnPermissionFlow flow, {
    Future<void> Function(WidgetTester tester)? interact,
  }) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      hostShell(
        Builder(
          builder: (BuildContext context) {
            pageContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
        strings: _strings,
      ),
    );

    final Future<TunnelPermissionResult> result = flow.ensureReady(pageContext);
    await tester.pumpAndSettle();
    if (interact != null) await interact(tester);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('existing consent starts without showing anything', (
    WidgetTester tester,
  ) async {
    final FakeCoreChannel channel = FakeCoreChannel(prepared: true);
    final VpnPermissionFlow flow = VpnPermissionFlow(
      channel: channel,
      host: ShellHostChannel(),
    );

    final TunnelPermissionResult result = await drive(tester, flow);

    expect(result, TunnelPermissionResult.ready);
    expect(channel.requestCalls, 0);
    expect(find.text('VPN permission required'), findsNothing);
  });

  testWidgets('the system dialog is explained before it is raised', (
    WidgetTester tester,
  ) async {
    final FakeCoreChannel channel = FakeCoreChannel(
      prepared: false,
      consentGranted: true,
    );
    final VpnPermissionFlow flow = VpnPermissionFlow(
      channel: channel,
      host: ShellHostChannel(),
    );

    final TunnelPermissionResult result = await drive(
      tester,
      flow,
      interact: (WidgetTester tester) async {
        expect(find.text('VPN permission required'), findsOneWidget);
        expect(
          channel.requestCalls,
          0,
          reason: 'the system dialog must wait for the explanation',
        );
        await tester.tap(find.text('Continue'));
      },
    );

    expect(result, TunnelPermissionResult.ready);
    expect(channel.requestCalls, 1);
  });

  testWidgets('backing out of the explanation never raises the dialog', (
    WidgetTester tester,
  ) async {
    final FakeCoreChannel channel = FakeCoreChannel(prepared: false);
    final VpnPermissionFlow flow = VpnPermissionFlow(
      channel: channel,
      host: ShellHostChannel(),
    );

    final TunnelPermissionResult result = await drive(
      tester,
      flow,
      interact: (WidgetTester tester) async {
        await tester.tap(find.text('Cancel'));
      },
    );

    expect(result, TunnelPermissionResult.cancelled);
    expect(channel.requestCalls, 0);
  });

  testWidgets('a refused grant is explained rather than swallowed', (
    WidgetTester tester,
  ) async {
    final FakeCoreChannel channel = FakeCoreChannel(
      prepared: false,
      consentGranted: false,
    );
    final VpnPermissionFlow flow = VpnPermissionFlow(
      channel: channel,
      host: ShellHostChannel(),
    );

    final TunnelPermissionResult result = await drive(
      tester,
      flow,
      interact: (WidgetTester tester) async {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('VPN permission denied'), findsOneWidget);
        await tester.tap(find.text('Dismiss'));
      },
    );

    expect(result, TunnelPermissionResult.vpnDeclined);
  });

  testWidgets('a host that cannot answer prepareVpn does not invent a story', (
    WidgetTester tester,
  ) async {
    final FakeCoreChannel channel = FakeCoreChannel(
      prepareThrows: const AikoCoreException(
        AikoCoreException.codeNotImplemented,
        'no host',
      ),
    );
    final VpnPermissionFlow flow = VpnPermissionFlow(
      channel: channel,
      host: ShellHostChannel(),
    );

    final TunnelPermissionResult result = await drive(tester, flow);

    expect(result, TunnelPermissionResult.ready);
    expect(find.text('VPN permission required'), findsNothing);
    expect(channel.requestCalls, 0);
  });

  group('notification permission', () {
    testWidgets('is asked for once and never blocks the start', (
      WidgetTester tester,
    ) async {
      mockHost(<String, Object?>{
        'notificationPermissionStatus': 'denied',
        'requestNotificationPermission': false,
      });
      final VpnPermissionFlow flow = VpnPermissionFlow(
        channel: FakeCoreChannel(prepared: true),
        host: ShellHostChannel(),
      );

      final TunnelPermissionResult first = await drive(
        tester,
        flow,
        interact: (WidgetTester tester) async {
          expect(find.text('Allow notifications'), findsOneWidget);
          await tester.tap(find.text('Not now'));
        },
      );
      expect(first, TunnelPermissionResult.ready);
      expect(hostCalls, contains('notificationPermissionStatus'));
      expect(hostCalls, isNot(contains('requestNotificationPermission')));

      hostCalls.clear();
      final TunnelPermissionResult second = await drive(tester, flow);
      expect(second, TunnelPermissionResult.ready);
      expect(find.text('Allow notifications'), findsNothing);
      expect(hostCalls, isNot(contains('requestNotificationPermission')));
    });

    testWidgets('a permanently denied state offers settings instead', (
      WidgetTester tester,
    ) async {
      mockHost(<String, Object?>{
        'notificationPermissionStatus': 'permanentlyDenied',
        'openNotificationSettings': true,
      });
      final VpnPermissionFlow flow = VpnPermissionFlow(
        channel: FakeCoreChannel(prepared: true),
        host: ShellHostChannel(),
      );

      final TunnelPermissionResult result = await drive(tester, flow);

      expect(result, TunnelPermissionResult.ready);
      expect(find.text('Allow notifications'), findsNothing);
      expect(find.text('Notifications are blocked.'), findsOneWidget);
      expect(find.text('Notification settings'), findsOneWidget);
    });

    testWidgets('a granted state is silent', (WidgetTester tester) async {
      mockHost(<String, Object?>{'notificationPermissionStatus': 'granted'});
      final VpnPermissionFlow flow = VpnPermissionFlow(
        channel: FakeCoreChannel(prepared: true),
        host: ShellHostChannel(),
      );

      await drive(tester, flow);

      expect(find.text('Allow notifications'), findsNothing);
      expect(find.text('Notifications are blocked.'), findsNothing);
    });
  });
}
