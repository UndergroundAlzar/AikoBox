/// User settings, JSON on disk, written atomically through a serial queue.
///
/// Ports the intent of `src/main/config/app.ts`: read-merge-write against the
/// defaults so a settings file written by an older build gains new keys instead
/// of failing to load, and every mutation is serialised so two concurrent
/// patches cannot lose one another.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config_store.dart';
import 'models.dart';
import 'paths.dart';

/// Reads and writes `<appSupport>/config.json`.
class AppConfigStore {
  AppConfigStore(this.file);

  /// Opens the store at the standard location.
  static Future<AppConfigStore> open() async {
    final dirs = await AikoDirs.ensure();
    return AppConfigStore(dirs.appConfigFile);
  }

  final File file;
  final SerialTaskQueue _queue = SerialTaskQueue();
  AppConfig? _cache;

  /// The most recently read or written value, or `null` before the first read.
  AppConfig? get cached => _cache;

  /// Reads the settings, falling back to defaults for anything missing.
  ///
  /// A settings file that is corrupt or not an object is replaced with the
  /// defaults rather than crashing the app on launch — the alternative is an
  /// unlaunchable app after a bad shutdown.
  Future<AppConfig> read({bool force = false}) => _queue.enqueue(() async {
    final cached = _cache;
    if (cached != null && !force) return cached;
    final config = await _readUnlocked();
    _cache = config;
    return config;
  });

  Future<AppConfig> _readUnlocked() async {
    if (!file.existsSync()) return AppConfig.defaults;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return AppConfig.defaults;
      return AppConfig.fromJson(<String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      });
    } catch (_) {
      return AppConfig.defaults;
    }
  }

  /// Replaces the settings wholesale.
  Future<AppConfig> write(AppConfig config) => _queue.enqueue(() async {
    await writeJsonFileAtomically(file, config.toJson());
    _cache = config;
    return config;
  });

  /// Read-modify-write under the queue, so [updater] always sees the value that
  /// is actually on disk and no concurrent patch is silently dropped.
  Future<AppConfig> update(AppConfig Function(AppConfig current) updater) =>
      _queue.enqueue(() async {
        final current = _cache ?? await _readUnlocked();
        final next = updater(current);
        if (next == current && _cache != null && file.existsSync()) {
          return current;
        }
        await writeJsonFileAtomically(file, next.toJson());
        _cache = next;
        return next;
      });

  /// Resolves once every queued write has settled. Used on app pause.
  Future<void> flush() => _queue.drain();
}
