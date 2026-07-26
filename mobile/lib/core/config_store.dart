/// Atomic, serialised, rollback-capable configuration storage.
///
/// Ports `src/main/core/singbox/configStore.ts`, `configPaths.ts`,
/// `serialTaskQueue.ts` and `remoteResource.ts:writeFileAtomically`.
///
/// Two non-negotiables live here:
///
/// * **N6** — every write to a mutable store is a temp file plus a rename, and
///   every mutation goes through a per-store FIFO queue.
/// * **N2/N3** — a new config is staged as a *candidate*, validated while the
///   running core still serves traffic, and only then promoted. The config that
///   was running is kept as *last-known-good*; a rejected one is kept as
///   *rejected* for diagnostics rather than deleted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// A failure-tolerant FIFO queue for state-changing operations.
///
/// A task that throws does not poison the queue: the next task still runs, and
/// the failure is delivered only to whoever enqueued it. Port of
/// `src/main/core/serialTaskQueue.ts`.
class SerialTaskQueue {
  Future<void> _tail = Future<void>.value();
  int _pendingCount = 0;

  bool get hasPending => _pendingCount > 0;

  int get pendingCount => _pendingCount;

  Future<T> enqueue<T>(Future<T> Function() task) {
    _pendingCount++;
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pendingCount--;
      }
    });
    return completer.future;
  }

  /// Resolves once everything queued so far has settled.
  Future<void> drain() => enqueue<void>(() async {});
}

final Random _tempSuffixRandom = Random();

String _tempName(String basename) {
  final suffix = _tempSuffixRandom
      .nextInt(1 << 32)
      .toRadixString(16)
      .padLeft(8, '0');
  return '.$basename.$pid.$suffix.tmp';
}

/// Writes [content] to [target] atomically: full write plus fsync into a
/// sibling temp file, then a rename over the target.
///
/// A crash can therefore leave the old content or the new content on disk, and
/// never a truncated mixture. The temp file is removed if the rename fails.
Future<void> writeFileAtomically(File target, String content) async {
  final directory = target.parent;
  if (!directory.existsSync()) {
    await directory.create(recursive: true);
  }
  final temporary = File(
    p.join(directory.path, _tempName(p.basename(target.path))),
  );
  try {
    await temporary.writeAsString(content, flush: true);
  } catch (error) {
    await _deleteQuietly(temporary);
    rethrow;
  }
  try {
    await temporary.rename(target.path);
  } catch (error) {
    await _deleteQuietly(temporary);
    rethrow;
  }
}

/// [writeFileAtomically] for a JSON document, pretty-printed so the rejected
/// slot is readable when someone has to diagnose a refusal by hand.
Future<void> writeJsonFileAtomically(File target, Map<String, dynamic> json) =>
    writeFileAtomically(
      target,
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );

Future<void> _deleteQuietly(File file) async {
  try {
    if (file.existsSync()) await file.delete();
  } catch (_) {
    // A temp file we cannot remove is litter, not a failure.
  }
}

/// Copies [source] onto [target] atomically, reading the whole source first.
Future<void> _replaceFileAtomically(File source, File target) async {
  await writeFileAtomically(target, await source.readAsString());
}

/// The four slots a config can occupy.
enum ConfigSlot {
  /// Converted but not yet validated. Never handed to a running core.
  candidate('candidate'),

  /// What the core is running right now.
  active('active'),

  /// The last config that started and stayed healthy. The N3 fallback.
  lastGood('last-good'),

  /// The most recent config the core refused. Kept for diagnostics only.
  rejected('rejected');

  const ConfigSlot(this.wireName);

  final String wireName;
}

/// What [SingboxConfigStore.restoreLastGood] handed back.
class RestoredConfig {
  const RestoredConfig({required this.config, this.runtimeProfile});

  /// The parsed sing-box JSON that is now in the active slot.
  final Map<String, dynamic> config;

  /// The matching Clash YAML, when one was stored alongside it.
  final String? runtimeProfile;
}

/// The candidate / active / last-known-good / rejected slot model, on disk.
///
/// File names match the desktop's `configPaths.ts` byte for byte so a support
/// dump from either platform reads the same way:
///
/// ```
/// sing-box.json              config.yaml
/// sing-box.candidate.json    config.candidate.yaml
/// sing-box.last-good.json    config.last-good.yaml
/// sing-box.rejected.json     config.rejected.yaml
/// ```
class SingboxConfigStore {
  SingboxConfigStore(this.workDir);

  static const String singboxConfigName = 'sing-box.json';
  static const String singboxCandidateConfigName = 'sing-box.candidate.json';
  static const String singboxLastGoodConfigName = 'sing-box.last-good.json';
  static const String singboxRejectedConfigName = 'sing-box.rejected.json';
  static const String runtimeProfileName = 'config.yaml';
  static const String runtimeCandidateProfileName = 'config.candidate.yaml';
  static const String runtimeLastGoodProfileName = 'config.last-good.yaml';
  static const String runtimeRejectedProfileName = 'config.rejected.yaml';

  final Directory workDir;
  final SerialTaskQueue _queue = SerialTaskQueue();

  bool get isBusy => _queue.hasPending;

  File _file(String name) => File(p.join(workDir.path, name));

  File get activeFile => _file(singboxConfigName);

  File get candidateFile => _file(singboxCandidateConfigName);

  File get lastGoodFile => _file(singboxLastGoodConfigName);

  File get rejectedFile => _file(singboxRejectedConfigName);

  File get runtimeActiveFile => _file(runtimeProfileName);

  File get runtimeCandidateFile => _file(runtimeCandidateProfileName);

  File get runtimeLastGoodFile => _file(runtimeLastGoodProfileName);

  File get runtimeRejectedFile => _file(runtimeRejectedProfileName);

  File fileForSlot(ConfigSlot slot) => switch (slot) {
    ConfigSlot.candidate => candidateFile,
    ConfigSlot.active => activeFile,
    ConfigSlot.lastGood => lastGoodFile,
    ConfigSlot.rejected => rejectedFile,
  };

  Future<void> ensureWorkDir() async {
    if (!workDir.existsSync()) await workDir.create(recursive: true);
  }

  /// Stages a converted config as the candidate. Does not touch the active
  /// slot, so the running core keeps serving traffic while it is validated.
  Future<void> writeCandidate(
    Map<String, dynamic> singboxConfig, {
    String? runtimeProfile,
  }) => _queue.enqueue(() async {
    await ensureWorkDir();
    await writeJsonFileAtomically(candidateFile, singboxConfig);
    if (runtimeProfile != null) {
      await writeFileAtomically(runtimeCandidateFile, runtimeProfile);
    }
  });

  /// Promotes the candidate to active.
  ///
  /// If no last-known-good exists yet, the config being displaced becomes one:
  /// a first successful start must leave something to roll back to.
  Future<void> promoteCandidate() => _queue.enqueue(() async {
    if (!candidateFile.existsSync()) {
      throw StateError('Converted sing-box candidate config is missing');
    }
    if (!lastGoodFile.existsSync() && activeFile.existsSync()) {
      await _replaceFileAtomically(activeFile, lastGoodFile);
    }
    if (!runtimeLastGoodFile.existsSync() && runtimeActiveFile.existsSync()) {
      await _replaceFileAtomically(runtimeActiveFile, runtimeLastGoodFile);
    }
    await _replaceFileAtomically(candidateFile, activeFile);
    if (runtimeCandidateFile.existsSync()) {
      await _replaceFileAtomically(runtimeCandidateFile, runtimeActiveFile);
    }
    await _deleteQuietly(candidateFile);
    await _deleteQuietly(runtimeCandidateFile);
  });

  /// Throws the candidate away without touching anything else. Used when
  /// validation rejects it before it was ever promoted.
  Future<void> discardCandidate() => _queue.enqueue(() async {
    if (candidateFile.existsSync()) {
      await _replaceFileAtomically(candidateFile, rejectedFile);
    }
    if (runtimeCandidateFile.existsSync()) {
      await _replaceFileAtomically(runtimeCandidateFile, runtimeRejectedFile);
    }
    await _deleteQuietly(candidateFile);
    await _deleteQuietly(runtimeCandidateFile);
  });

  /// Records the active config as last-known-good.
  ///
  /// Called on the stability timer, not at start: a config that starts and dies
  /// forty seconds later is not good.
  Future<void> markActiveGood() => _queue.enqueue(() async {
    if (!activeFile.existsSync()) return;
    await _replaceFileAtomically(activeFile, lastGoodFile);
    if (runtimeActiveFile.existsSync()) {
      await _replaceFileAtomically(runtimeActiveFile, runtimeLastGoodFile);
    }
  });

  /// Rolls the active slot back to the last-known-good config (N3).
  ///
  /// Returns `null` when there is nothing to roll back to — the caller must
  /// then surface the original failure rather than pretend it recovered.
  ///
  /// [retainActiveAsRejected] is false on a cold start, where the active config
  /// was never actually run and labelling it "rejected" would be a lie.
  Future<RestoredConfig?> restoreLastGood({
    bool retainActiveAsRejected = true,
  }) => _queue.enqueue(() async {
    if (!lastGoodFile.existsSync()) return null;

    if (retainActiveAsRejected && activeFile.existsSync()) {
      try {
        await _replaceFileAtomically(activeFile, rejectedFile);
      } catch (_) {
        // Keeping a diagnostic copy is best-effort; the rollback matters.
      }
    }
    await _replaceFileAtomically(lastGoodFile, activeFile);

    String? runtimeProfile;
    if (runtimeLastGoodFile.existsSync()) {
      if (retainActiveAsRejected && runtimeActiveFile.existsSync()) {
        try {
          await _replaceFileAtomically(runtimeActiveFile, runtimeRejectedFile);
        } catch (_) {
          // Same: diagnostics only.
        }
      }
      await _replaceFileAtomically(runtimeLastGoodFile, runtimeActiveFile);
      runtimeProfile = await runtimeActiveFile.readAsString();
    }

    final raw = await activeFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException(
        'Last-known-good sing-box config is not a JSON object',
      );
    }
    return RestoredConfig(
      config: <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      },
      runtimeProfile: runtimeProfile,
    );
  });

  /// Reads a slot's raw text, or `null` when the slot is empty.
  Future<String?> readSlot(ConfigSlot slot) => _queue.enqueue(() async {
    final file = fileForSlot(slot);
    if (!file.existsSync()) return null;
    return file.readAsString();
  });

  /// Reads a slot as JSON, or `null` when the slot is empty or unparseable.
  Future<Map<String, dynamic>?> readSlotJson(ConfigSlot slot) async {
    final raw = await readSlot(slot);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    } catch (_) {
      return null;
    }
  }

  bool get hasLastGood => lastGoodFile.existsSync();

  bool get hasActive => activeFile.existsSync();

  bool get hasCandidate => candidateFile.existsSync();

  /// Removes every slot. Only used when the user deletes all profiles — a
  /// stale last-known-good pointing at a deleted subscription is worse than
  /// no fallback at all.
  Future<void> clear() => _queue.enqueue(() async {
    for (final file in <File>[
      activeFile,
      candidateFile,
      lastGoodFile,
      rejectedFile,
      runtimeActiveFile,
      runtimeCandidateFile,
      runtimeLastGoodFile,
      runtimeRejectedFile,
    ]) {
      await _deleteQuietly(file);
    }
  });
}
