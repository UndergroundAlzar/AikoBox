import 'package:aikobox_android/platform/vpn_bridge.dart';
import 'package:aikobox_android/platform/vpn_state.dart';
import 'package:aikobox_android/profiles/profile.dart';
import 'package:aikobox_android/profiles/profile_controller.dart';
import 'package:aikobox_android/profiles/profile_import_service.dart';
import 'package:aikobox_android/profiles/profile_repository.dart';
import 'package:aikobox_android/profiles/profiles_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native validation failure removes the newly persisted orphan',
    () async {
      final store = _TrackingStore();
      final importService = ProfileImportService(fileStore: store);
      final controller = ProfileController(MemoryProfileRepository());
      await controller.load();
      final pending = importService.fromPasted('{}');

      await expectLater(
        commitImportedProfile(
          pending: pending,
          importService: importService,
          vpnBridge: const _RejectingBridge(),
          controller: controller,
        ),
        throwsA(isA<VpnBridgeException>()),
      );

      expect(store.deleted, hasLength(1));
      expect(controller.profiles, isEmpty);
      controller.dispose();
    },
  );

  test('switching profiles while running reloads before selecting', () async {
    final oldProfile = _profile('old');
    final nextProfile = _profile('next');
    final controller = ProfileController(
      MemoryProfileRepository([oldProfile, nextProfile]),
    );
    await controller.load();
    controller.restoreSelection(
      activeProfilePath: oldProfile.path,
      allowFallback: false,
    );
    final bridge = _RunningBridge(oldProfile.path!);

    await selectProfileSafely(
      controller: controller,
      vpnBridge: bridge,
      profile: nextProfile,
    );

    expect(bridge.reloadedPath, nextProfile.path);
    expect(controller.selected?.id, nextProfile.id);
    expect(isProfileActive(await bridge.getStatus(), nextProfile), isTrue);
    controller.dispose();
  });

  test('transitioning VPN rejects selection without changing the UI', () async {
    final oldProfile = _profile('old');
    final nextProfile = _profile('next');
    final controller = ProfileController(
      MemoryProfileRepository([oldProfile, nextProfile]),
    );
    await controller.load();
    controller.restoreSelection(
      activeProfilePath: oldProfile.path,
      allowFallback: false,
    );

    await expectLater(
      selectProfileSafely(
        controller: controller,
        vpnBridge: const _StaticBridge(VpnState.starting),
        profile: nextProfile,
      ),
      throwsA(isA<VpnBridgeException>()),
    );

    expect(controller.selected?.id, oldProfile.id);
    controller.dispose();
  });

  test('failed reload rolls back to the previously selected profile', () async {
    final oldProfile = _profile('old');
    final nextProfile = _profile('next');
    final controller = ProfileController(
      MemoryProfileRepository([oldProfile, nextProfile]),
    );
    await controller.load();
    controller.restoreSelection(
      activeProfilePath: oldProfile.path,
      allowFallback: false,
    );

    await expectLater(
      selectProfileSafely(
        controller: controller,
        vpnBridge: _FailingReloadBridge(oldProfile.path!),
        profile: nextProfile,
      ),
      throwsA(isA<VpnBridgeException>()),
    );

    expect(controller.selected?.id, oldProfile.id);
    controller.dispose();
  });
}

Profile _profile(String id) => Profile(
  id: id,
  name: id,
  json: '{}',
  source: ProfileSource.pasted,
  createdAt: DateTime.utc(2026, 7, 27),
  path: '/private/$id.json',
);

class _TrackingStore implements ProfileFileStore {
  final deleted = <String>[];

  @override
  Future<void> delete(Profile profile) async {
    deleted.add(profile.id);
  }

  @override
  Future<Profile> persist(Profile profile) async {
    return profile.copyWith(path: '/private/${profile.id}.json');
  }
}

class _RejectingBridge implements VpnBridge {
  const _RejectingBridge();

  @override
  Future<void> checkProfile(String path) {
    throw const VpnBridgeException('invalid profile');
  }

  @override
  Future<VpnStatus> getStatus() async =>
      const VpnStatus(state: VpnState.stopped);

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<void> reload(String profilePath) async {}

  @override
  Future<void> start(String profilePath) async {}

  @override
  Stream<VpnStatus> get statusEvents => const Stream.empty();

  @override
  Future<void> stop() async {}
}

class _RunningBridge implements VpnBridge {
  _RunningBridge(this.activePath);

  String activePath;
  String? reloadedPath;

  @override
  Future<void> checkProfile(String path) async {}

  @override
  Future<VpnStatus> getStatus() async =>
      VpnStatus(state: VpnState.running, activeProfilePath: activePath);

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<void> reload(String profilePath) async {
    reloadedPath = profilePath;
    activePath = profilePath;
  }

  @override
  Future<void> start(String profilePath) async {}

  @override
  Stream<VpnStatus> get statusEvents => const Stream.empty();

  @override
  Future<void> stop() async {}
}

class _StaticBridge implements VpnBridge {
  const _StaticBridge(this.state);

  final VpnState state;

  @override
  Future<void> checkProfile(String path) async {}

  @override
  Future<VpnStatus> getStatus() async => VpnStatus(state: state);

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<void> reload(String profilePath) async {}

  @override
  Future<void> start(String profilePath) async {}

  @override
  Stream<VpnStatus> get statusEvents => const Stream.empty();

  @override
  Future<void> stop() async {}
}

class _FailingReloadBridge extends _RunningBridge {
  _FailingReloadBridge(super.activePath);

  @override
  Future<void> reload(String profilePath) async {
    throw const VpnBridgeException('reload failed');
  }
}
