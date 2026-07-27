import 'package:aikobox_android/app.dart';
import 'package:aikobox_android/platform/vpn_bridge.dart';
import 'package:aikobox_android/platform/vpn_state.dart';
import 'package:aikobox_android/profiles/profile.dart';
import 'package:aikobox_android/profiles/profile_import_service.dart';
import 'package:aikobox_android/profiles/profile_repository.dart';
import 'package:aikobox_android/settings/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the adaptive Material 3 shell and navigation', (
    tester,
  ) async {
    final settings = SettingsController();
    await settings.load();
    await tester.pumpWidget(
      AikoBoxApp(
        profileRepository: MemoryProfileRepository(),
        importService: ProfileImportService(),
        vpnBridge: const _FakeVpnBridge(),
        settingsController: settings,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AikoBox'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('配置'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
  });

  testWidgets('restores the native active profile after Activity rebuild', (
    tester,
  ) async {
    final settings = SettingsController();
    await settings.load();
    final first = _profile('first');
    final active = _profile('active');

    await tester.pumpWidget(
      AikoBoxApp(
        profileRepository: MemoryProfileRepository([first, active]),
        importService: ProfileImportService(),
        vpnBridge: _FakeVpnBridge(
          VpnStatus(state: VpnState.running, activeProfilePath: active.path),
        ),
        settingsController: settings,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('active'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });
}

class _FakeVpnBridge implements VpnBridge {
  const _FakeVpnBridge([
    this.status = const VpnStatus(state: VpnState.stopped),
  ]);

  final VpnStatus status;

  @override
  Stream<VpnStatus> get statusEvents => const Stream.empty();

  @override
  Future<void> checkProfile(String path) async {}

  @override
  Future<VpnStatus> getStatus() async {
    return status;
  }

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<void> reload(String profilePath) async {}

  @override
  Future<void> start(String profilePath) async {}

  @override
  Future<void> stop() async {}
}

Profile _profile(String id) => Profile(
  id: id,
  name: id,
  json: '{}',
  source: ProfileSource.pasted,
  createdAt: DateTime.utc(2026, 7, 27),
  path: '/private/$id.json',
);
