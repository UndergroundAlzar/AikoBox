import 'package:aikobox_mobile/features/shell/shell_host_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(ShellHostChannel.channelName);
  final List<String> calls = <String>[];

  void handle(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          return handler == null ? null : await handler(call);
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('with no host implementation', () {
    test('every call degrades instead of throwing', () async {
      final ShellHostChannel host = ShellHostChannel();

      expect(host.isAvailable, isTrue);
      expect(
        await host.notificationPermissionStatus(),
        NotificationPermission.unsupported,
      );
      expect(host.isAvailable, isFalse);
      expect(await host.requestNotificationPermission(), isFalse);
      expect(await host.openNotificationSettings(), isFalse);
      expect(await host.openVpnSettings(), isFalse);
    });

    test('the missing channel is only probed once', () async {
      final ShellHostChannel host = ShellHostChannel();
      await host.notificationPermissionStatus();
      await host.notificationPermissionStatus();
      await host.openVpnSettings();
      expect(calls, isEmpty, reason: 'no mock handler is installed');
      expect(host.isAvailable, isFalse);
    });
  });

  group('with a host implementation', () {
    test('permission states map off the wire', () async {
      final Map<String, NotificationPermission> expected =
          <String, NotificationPermission>{
            'granted': NotificationPermission.granted,
            'denied': NotificationPermission.denied,
            'permanentlyDenied': NotificationPermission.permanentlyDenied,
            'unsupported': NotificationPermission.unsupported,
            'nonsense-from-a-newer-host': NotificationPermission.unsupported,
          };

      for (final MapEntry<String, NotificationPermission> entry
          in expected.entries) {
        handle((MethodCall call) async => entry.key);
        expect(
          await ShellHostChannel().notificationPermissionStatus(),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('a host error is swallowed, not rethrown', () async {
      handle(
        (MethodCall call) async =>
            throw PlatformException(code: 'E_NO_ACTIVITY'),
      );
      final ShellHostChannel host = ShellHostChannel();

      expect(await host.openVpnSettings(), isFalse);
      // A failing call is not a missing channel; later calls still go out.
      expect(host.isAvailable, isTrue);
    });

    test('booleans come back verbatim', () async {
      handle((MethodCall call) async => true);
      final ShellHostChannel host = ShellHostChannel();

      expect(await host.requestNotificationPermission(), isTrue);
      expect(await host.openNotificationSettings(), isTrue);
      expect(await host.openVpnSettings(), isTrue);
      expect(calls, <String>[
        'requestNotificationPermission',
        'openNotificationSettings',
        'openVpnSettings',
      ]);
    });
  });
}
