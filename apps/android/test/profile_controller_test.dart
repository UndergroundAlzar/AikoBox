import 'dart:async';
import 'dart:convert';

import 'package:aikobox_android/profiles/profile.dart';
import 'package:aikobox_android/profiles/profile_controller.dart';
import 'package:aikobox_android/profiles/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Profile profile(String id) {
    return Profile(
      id: id,
      name: '配置 $id',
      json: '{}',
      source: ProfileSource.pasted,
      createdAt: DateTime.utc(2026, 7, 27),
      path: '/private/$id.json',
    );
  }

  test('shares selection and persisted profile changes', () async {
    final first = profile('first');
    final second = profile('second');
    final repository = MemoryProfileRepository([first]);
    final controller = ProfileController(repository);

    await controller.load();
    expect(controller.selected, isNull);
    controller.restoreSelection(activeProfilePath: null, allowFallback: true);
    expect(controller.selected?.id, 'first');

    await controller.add(second);
    expect(controller.selected?.id, 'second');
    expect((await repository.load()).map((item) => item.id), [
      'second',
      'first',
    ]);

    await controller.remove(second);
    expect(controller.selected?.id, 'first');
    controller.dispose();
  });

  test('restores the native active profile after repository loading', () async {
    final first = profile('first');
    final active = profile('active');
    final repository = _DelayedRepository();
    final controller = ProfileController(repository);

    final pending = controller.load();
    controller.restoreSelection(
      activeProfilePath: active.path,
      allowFallback: false,
    );
    repository.complete([first, active]);
    await pending;

    expect(controller.selected?.id, 'active');
    controller.dispose();
  });

  test(
    'does not misrepresent first profile when active path is unknown',
    () async {
      final controller = ProfileController(
        MemoryProfileRepository([profile('first')]),
      );
      await controller.load();

      controller.restoreSelection(
        activeProfilePath: '/private/missing.json',
        allowFallback: false,
      );

      expect(controller.selected, isNull);
      controller.dispose();
    },
  );

  test('persisted metadata never duplicates full profile JSON', () {
    final encoded = Profile.encodeList([profile('first')]);
    final decoded = jsonDecode(encoded) as List<Object?>;
    final metadata = (decoded.single! as Map).cast<String, Object?>();

    expect(metadata, isNot(contains('json')));
    expect(metadata['path'], '/private/first.json');
  });

  test('late repository load is ignored after controller disposal', () async {
    final repository = _DelayedRepository();
    final controller = ProfileController(repository);
    final pending = controller.load();

    controller.dispose();
    repository.complete([profile('late')]);

    await pending;
    expect(controller.profiles, isEmpty);
  });
}

class _DelayedRepository implements ProfileRepository {
  final _completer = Completer<List<Profile>>();

  void complete(List<Profile> profiles) => _completer.complete(profiles);

  @override
  Future<List<Profile>> load() => _completer.future;

  @override
  Future<void> save(List<Profile> profiles) async {}
}
