import 'package:aikobox_android/platform/vpn_bridge.dart';
import 'package:aikobox_android/platform/vpn_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.aikobox/vpn');
  const events = EventChannel('test.aikobox/vpn/events');
  final calls = <MethodCall>[];
  final bridge = MethodChannelVpnBridge(
    methodChannel: channel,
    eventChannel: events,
  );

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'prepareVpn' => true,
            'getStatus' => <String, Object>{
              'state': 'running',
              'activeProfilePath': '/private/profile.json',
              'message':
                  'https://user:pass@example.com/config?token=abc password=hunter2',
            },
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the stable native method contract', () async {
    expect(await bridge.prepareVpn(), isTrue);
    await bridge.checkProfile('/private/profile.json');
    await bridge.start('/private/profile.json');
    await bridge.reload('/private/profile.json');
    await bridge.stop();
    final status = await bridge.getStatus();

    expect(status.state, VpnState.running);
    expect(status.activeProfilePath, '/private/profile.json');
    expect(status.message, isNot(contains('hunter2')));
    expect(status.message, isNot(contains('token=abc')));
    expect(calls[1].arguments, {'profilePath': '/private/profile.json'});
    expect(calls.map((call) => call.method), [
      'prepareVpn',
      'checkProfile',
      'start',
      'reload',
      'stop',
      'getStatus',
    ]);
  });

  test('redacts native platform errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'start_failed',
            message:
                'https://user:pass@example.com/config?token=abc password=hunter2',
          );
        });

    await expectLater(
      bridge.start('/private/profile.json'),
      throwsA(
        isA<VpnBridgeException>().having(
          (error) => error.message,
          'message',
          allOf(
            isNot(contains('hunter2')),
            isNot(contains('token=abc')),
            isNot(contains('user:pass')),
          ),
        ),
      ),
    );
  });
}
