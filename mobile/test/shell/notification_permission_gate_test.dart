import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/shell/notification_permission_gate.dart';
import 'package:aikobox_mobile/features/shell/shell_host_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shell_harness.dart';

const Map<String, String> _strings = <String, String>{
  'notification.permission.title': 'Allow notifications',
  'notification.permission.message': 'Android requires a notification.',
  'notification.permission.denied': 'Notifications are blocked.',
  'notification.settings': 'Notification settings',
  'common.allow': 'Allow',
  'common.notNow': 'Not now',
};

/// Replaces the real notifier so the test can move the core through its
/// states without a platform channel or a controller behind it.
class _ScriptedCoreStatus extends CoreStatusNotifier {
  @override
  CoreStatus build() => CoreStatus.stopped;

  void publish(CoreState next) => state = CoreStatus(state: next);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel hostChannel = MethodChannel(ShellHostChannel.channelName);
  final List<String> hostCalls = <String>[];

  setUp(() {
    hostCalls.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (MethodCall call) async {
          hostCalls.add(call.method);
          return switch (call.method) {
            'notificationPermissionStatus' => 'denied',
            'requestNotificationPermission' => true,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, null);
  });

  Future<ProviderContainer> pumpGate(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [coreStatusProvider.overrideWith(_ScriptedCoreStatus.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      hostShell(
        const NotificationPermissionGate(
          child: Scaffold(body: SizedBox.expand()),
        ),
        strings: _strings,
        container: container,
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  _ScriptedCoreStatus statusOf(ProviderContainer container) =>
      container.read(coreStatusProvider.notifier) as _ScriptedCoreStatus;

  testWidgets('nothing is asked while the core is stopped', (
    WidgetTester tester,
  ) async {
    await pumpGate(tester);

    expect(find.text('Allow notifications'), findsNothing);
    expect(hostCalls, isEmpty);
  });

  testWidgets('the prompt appears the first time a tunnel comes up', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpGate(tester);

    statusOf(container).publish(CoreState.starting);
    await tester.pumpAndSettle();

    expect(find.text('Allow notifications'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(hostCalls, contains('requestNotificationPermission'));
  });

  testWidgets('a second start in the same session does not re-prompt', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpGate(tester);
    final _ScriptedCoreStatus status = statusOf(container);

    status.publish(CoreState.starting);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    status.publish(CoreState.stopped);
    await tester.pumpAndSettle();
    status.publish(CoreState.starting);
    await tester.pumpAndSettle();

    expect(find.text('Allow notifications'), findsNothing);
  });

  testWidgets('shutting down never raises the prompt', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pumpGate(tester);
    final _ScriptedCoreStatus status = statusOf(container);

    // Only a transition *into* an active state counts. `stopping` and
    // `stopped` are not active, so neither may reach the host again.
    status.publish(CoreState.running);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    hostCalls.clear();

    status.publish(CoreState.stopping);
    await tester.pumpAndSettle();
    status.publish(CoreState.stopped);
    await tester.pumpAndSettle();

    expect(find.text('Allow notifications'), findsNothing);
    expect(hostCalls, isEmpty);
  });
}
