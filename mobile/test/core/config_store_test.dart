import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Port of `src/main/core/singbox/configStore.test.ts`, plus coverage for the
/// atomic-write and serial-queue primitives the desktop tests take for granted.
void main() {
  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('aikobox-config-store-');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  String configJson(String name) =>
      '${jsonEncode(<String, String>{'name': name})}\n';

  void seed(File file, String content) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String? nameIn(File file) {
    if (!file.existsSync()) return null;
    return (jsonDecode(file.readAsStringSync()) as Map)['name'] as String?;
  }

  group('writeFileAtomically', () {
    test('creates missing parent directories', () async {
      final target = File(p.join(workDir.path, 'a', 'b', 'c.json'));
      await writeFileAtomically(target, 'hello');
      expect(target.readAsStringSync(), 'hello');
    });

    test('replaces existing content and leaves no temp files behind', () async {
      final target = File(p.join(workDir.path, 'settings.json'));
      await writeFileAtomically(target, 'first');
      await writeFileAtomically(target, 'second');

      expect(target.readAsStringSync(), 'second');
      final leftovers = workDir
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).endsWith('.tmp'))
          .toList();
      expect(
        leftovers,
        isEmpty,
        reason: 'the temp file must be renamed, not left',
      );
    });

    test('never leaves a partially written target', () async {
      // The target only ever becomes visible via rename, so a reader either
      // sees the whole previous document or the whole new one.
      final target = File(p.join(workDir.path, 'atomic.json'));
      await writeFileAtomically(target, configJson('old'));

      final observed = <String?>[];
      final writer = writeFileAtomically(target, configJson('new'));
      for (var i = 0; i < 8; i++) {
        observed.add(nameIn(target));
        await Future<void>.delayed(Duration.zero);
      }
      await writer;
      observed.add(nameIn(target));

      expect(observed.toSet().difference(<String?>{'old', 'new'}), isEmpty);
      expect(observed.last, 'new');
    });

    test('a write into a path that cannot exist leaves no temp file', () async {
      // A directory where a file is expected makes the rename fail.
      final blocker = Directory(p.join(workDir.path, 'blocked.json'))
        ..createSync(recursive: true);
      await expectLater(
        writeFileAtomically(File(blocker.path), 'x'),
        throwsA(isA<FileSystemException>()),
      );
      final leftovers = workDir.listSync().whereType<File>().where(
        (file) => p.basename(file.path).endsWith('.tmp'),
      );
      expect(leftovers, isEmpty);
    });
  });

  group('SerialTaskQueue', () {
    test(
      'runs tasks in FIFO order even when they finish out of order',
      () async {
        final queue = SerialTaskQueue();
        final order = <int>[];

        final first = queue.enqueue(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          order.add(1);
          return 1;
        });
        final second = queue.enqueue(() async {
          order.add(2);
          return 2;
        });
        final third = queue.enqueue(() async {
          order.add(3);
          return 3;
        });

        expect(queue.hasPending, isTrue);
        expect(await Future.wait(<Future<int>>[first, second, third]), <int>[
          1,
          2,
          3,
        ]);
        expect(order, <int>[1, 2, 3]);
        await queue.drain();
        expect(queue.hasPending, isFalse);
      },
    );

    test('a failing task does not poison the queue', () async {
      final queue = SerialTaskQueue();
      final failing = queue.enqueue<int>(() async => throw StateError('boom'));

      await expectLater(failing, throwsA(isA<StateError>()));
      expect(await queue.enqueue(() async => 7), 7);
      await queue.drain();
      expect(queue.hasPending, isFalse);
    });

    test('the failure reaches only the caller that enqueued it', () async {
      final queue = SerialTaskQueue();
      final failing = queue.enqueue<void>(() async => throw StateError('boom'));
      final following = queue.enqueue(() async => 'ok');

      await expectLater(failing, throwsA(isA<StateError>()));
      expect(await following, 'ok');
    });
  });

  group('SingboxConfigStore slots', () {
    late SingboxConfigStore store;

    setUp(() {
      store = SingboxConfigStore(workDir);
    });

    test(
      'promotes a candidate while seeding the previous active config as LKG',
      () async {
        seed(store.activeFile, configJson('old'));
        seed(store.runtimeActiveFile, 'name: old\n');
        await store.writeCandidate(<String, dynamic>{
          'name': 'candidate',
        }, runtimeProfile: 'name: candidate\n');

        await store.promoteCandidate();

        expect(nameIn(store.activeFile), 'candidate');
        expect(nameIn(store.lastGoodFile), 'old');
        expect(store.runtimeActiveFile.readAsStringSync(), 'name: candidate\n');
        expect(store.runtimeLastGoodFile.readAsStringSync(), 'name: old\n');
        expect(store.candidateFile.existsSync(), isFalse);
        expect(store.runtimeCandidateFile.existsSync(), isFalse);
      },
    );

    test('does not overwrite an existing LKG when promoting', () async {
      seed(store.lastGoodFile, configJson('trusted'));
      seed(store.activeFile, configJson('old'));
      await store.writeCandidate(<String, dynamic>{'name': 'candidate'});

      await store.promoteCandidate();

      expect(nameIn(store.activeFile), 'candidate');
      expect(nameIn(store.lastGoodFile), 'trusted');
    });

    test('refuses to promote when no candidate was staged', () async {
      seed(store.activeFile, configJson('old'));
      await expectLater(store.promoteCandidate(), throwsA(isA<StateError>()));
      expect(nameIn(store.activeFile), 'old');
    });

    test('marks a healthy active config as last-known-good', () async {
      seed(store.activeFile, configJson('healthy'));
      seed(store.runtimeActiveFile, 'name: healthy\n');

      await store.markActiveGood();

      expect(nameIn(store.lastGoodFile), 'healthy');
      expect(store.runtimeLastGoodFile.readAsStringSync(), 'name: healthy\n');
    });

    test('marking is a no-op when nothing is active', () async {
      await store.markActiveGood();
      expect(store.lastGoodFile.existsSync(), isFalse);
    });

    test(
      'restores LKG and retains the rejected config for diagnostics',
      () async {
        seed(store.activeFile, configJson('bad'));
        seed(store.lastGoodFile, configJson('good'));
        seed(store.runtimeActiveFile, 'name: bad\n');
        seed(store.runtimeLastGoodFile, 'name: good\n');

        final restored = await store.restoreLastGood();

        expect(restored, isNotNull);
        expect(restored!.config['name'], 'good');
        expect(restored.runtimeProfile, 'name: good\n');
        expect(nameIn(store.activeFile), 'good');
        expect(nameIn(store.rejectedFile), 'bad');
        expect(store.runtimeRejectedFile.readAsStringSync(), 'name: bad\n');
      },
    );

    test('restores a cold-start LKG without mislabeling the previous active '
        'snapshot', () async {
      seed(store.activeFile, configJson('previous-active'));
      seed(store.lastGoodFile, configJson('good'));
      seed(store.runtimeActiveFile, 'name: previous-active\n');
      seed(store.runtimeLastGoodFile, 'name: good\n');

      final restored = await store.restoreLastGood(
        retainActiveAsRejected: false,
      );

      expect(restored!.config['name'], 'good');
      expect(store.rejectedFile.existsSync(), isFalse);
      expect(store.runtimeRejectedFile.existsSync(), isFalse);
    });

    test('reports that there is nothing to roll back to', () async {
      seed(store.activeFile, configJson('bad'));
      expect(await store.restoreLastGood(), isNull);
      // The active config is left exactly as it was: an absent LKG must not
      // cost the user the config they already had.
      expect(nameIn(store.activeFile), 'bad');
    });

    test(
      'a discarded candidate is kept as rejected and never promoted',
      () async {
        seed(store.activeFile, configJson('serving'));
        await store.writeCandidate(<String, dynamic>{
          'name': 'broken',
        }, runtimeProfile: 'name: broken\n');

        await store.discardCandidate();

        expect(
          nameIn(store.activeFile),
          'serving',
          reason: 'the running core is untouched',
        );
        expect(nameIn(store.rejectedFile), 'broken');
        expect(store.runtimeRejectedFile.readAsStringSync(), 'name: broken\n');
        expect(store.candidateFile.existsSync(), isFalse);
        expect(store.hasCandidate, isFalse);
      },
    );

    test(
      'the full N2/N3 sequence: promote, prove good, then roll back',
      () async {
        // 1. First config ever. Nothing to fall back to yet.
        await store.writeCandidate(<String, dynamic>{'name': 'v1'});
        await store.promoteCandidate();
        expect(nameIn(store.activeFile), 'v1');
        expect(store.hasLastGood, isFalse);

        // 2. It stayed up, so it becomes the fallback.
        await store.markActiveGood();
        expect(nameIn(store.lastGoodFile), 'v1');

        // 3. A new config is staged and promoted...
        await store.writeCandidate(<String, dynamic>{'name': 'v2'});
        await store.promoteCandidate();
        expect(nameIn(store.activeFile), 'v2');

        // 4. ...then fails at runtime, so v1 comes back and v2 is kept for
        //    diagnostics rather than thrown away.
        final restored = await store.restoreLastGood();
        expect(restored!.config['name'], 'v1');
        expect(nameIn(store.activeFile), 'v1');
        expect(nameIn(store.rejectedFile), 'v2');
      },
    );

    test('concurrent mutations are serialised, not interleaved', () async {
      seed(store.activeFile, configJson('base'));
      await Future.wait(<Future<void>>[
        store.writeCandidate(<String, dynamic>{'name': 'a'}),
        store.markActiveGood(),
        store.writeCandidate(<String, dynamic>{'name': 'b'}),
      ]);

      // Whichever candidate landed last, the file is one complete document.
      expect(<String?>['a', 'b'], contains(nameIn(store.candidateFile)));
      expect(nameIn(store.lastGoodFile), 'base');
    });

    test('readSlotJson tolerates a corrupt slot', () async {
      seed(store.activeFile, 'not json at all');
      expect(await store.readSlotJson(ConfigSlot.active), isNull);
      expect(await store.readSlot(ConfigSlot.active), 'not json at all');
      expect(await store.readSlotJson(ConfigSlot.lastGood), isNull);
    });

    test(
      'restoring a corrupt LKG fails loudly rather than half-applying',
      () async {
        seed(store.activeFile, configJson('bad'));
        seed(store.lastGoodFile, 'definitely not json');

        await expectLater(
          store.restoreLastGood(),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('clear removes every slot', () async {
      seed(store.activeFile, configJson('a'));
      seed(store.lastGoodFile, configJson('b'));
      seed(store.rejectedFile, configJson('c'));
      seed(store.runtimeActiveFile, 'name: a\n');

      await store.clear();

      expect(store.hasActive, isFalse);
      expect(store.hasLastGood, isFalse);
      expect(store.rejectedFile.existsSync(), isFalse);
      expect(store.runtimeActiveFile.existsSync(), isFalse);
    });
  });
}
