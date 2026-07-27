import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile.dart';

abstract interface class ProfileRepository {
  Future<List<Profile>> load();
  Future<void> save(List<Profile> profiles);
}

class SharedPreferencesProfileRepository implements ProfileRepository {
  static const _key = 'profiles.v1';

  @override
  Future<List<Profile>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_key);
    if (value == null || value.isEmpty) {
      return const [];
    }
    final profiles = Profile.decodeList(value);
    return Future.wait(
      profiles.map((profile) async {
        final path = profile.path;
        if (path == null) {
          return profile;
        }
        final file = File(path);
        if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
          return profile;
        }
        return Profile(
          id: profile.id,
          name: profile.name,
          json: await file.readAsString(),
          source: profile.source,
          createdAt: profile.createdAt,
          sourceHost: profile.sourceHost,
          path: path,
        );
      }),
    );
  }

  @override
  Future<void> save(List<Profile> profiles) async {
    final preferences = await SharedPreferences.getInstance();
    final previousValue = preferences.getString(_key);
    final encoded = Profile.encodeList(profiles);
    final persisted = await preferences.setString(_key, encoded);
    if (!persisted) {
      throw const ProfileRepositoryException('无法保存配置元数据');
    }
    if (previousValue != null && previousValue.isNotEmpty) {
      final retainedPaths = profiles.map((profile) => profile.path).toSet();
      final supportDirectory = await getApplicationSupportDirectory();
      final profilesRoot =
          '${Directory(supportDirectory.path).absolute.path}'
          '${Platform.pathSeparator}profiles${Platform.pathSeparator}';
      for (final previous in Profile.decodeList(previousValue)) {
        final path = previous.path;
        if (path != null && !retainedPaths.contains(path)) {
          final file = File(path).absolute;
          final isManagedProfile =
              file.path.startsWith(profilesRoot) &&
              file.path.toLowerCase().endsWith('.json');
          if (isManagedProfile && await file.exists()) {
            await file.delete();
          }
        }
      }
    }
  }
}

class ProfileRepositoryException implements Exception {
  const ProfileRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MemoryProfileRepository implements ProfileRepository {
  MemoryProfileRepository([List<Profile> initial = const []])
    : _profiles = List.of(initial);

  List<Profile> _profiles;

  @override
  Future<List<Profile>> load() async => List.unmodifiable(_profiles);

  @override
  Future<void> save(List<Profile> profiles) async {
    _profiles = List.of(profiles);
  }
}
