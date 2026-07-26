import 'dart:io';

import 'package:aikobox_mobile/core/paths.dart';
import 'package:aikobox_mobile/features/profiles/data/profile_overlay_store.dart';
import 'package:aikobox_mobile/features/profiles/data/rule_overlay.dart';
import 'package:aikobox_mobile/features/profiles/data/yaml_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for `ProfileStore`'s content read/write pair.
class _FakeProfileFiles {
  final Map<String, String> contents = <String, String>{};
  final List<String> writes = <String>[];

  Future<String> read(String id) async {
    final value = contents[id];
    if (value == null) throw StateError('Profile $id has no stored content');
    return value;
  }

  Future<void> write(String id, String content) async {
    contents[id] = content;
    writes.add(id);
  }
}

const String _profileYaml = '''
mixed-port: 7890
rules:
  - DOMAIN,a.com,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
''';

void main() {
  late Directory root;
  late AikoDirs dirs;
  late _FakeProfileFiles files;
  late ProfileOverlayStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aiko-overlay-test');
    dirs = AikoDirs(root);
    await dirs.createAll();
    files = _FakeProfileFiles()..contents['p1'] = _profileYaml;
    store = ProfileOverlayStore(
      dirs: dirs,
      readProfile: files.read,
      writeProfile: files.write,
    );
  });

  tearDown(() async {
    await store.drain();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  List<String> rulesOf(String yaml) =>
      normaliseRuleList(parseYamlMap(yaml)['rules']);

  group('with no overlay', () {
    test('nothing is stored and the profile is its own source', () async {
      expect(store.hasOverlay('p1'), isFalse);
      expect(store.isMaterialised('p1'), isFalse);
      expect(await store.readProfileSource('p1'), _profileYaml);
      expect((await store.readOverlay('p1')).exists, isFalse);
    });

    test('a hand edit writes straight through', () async {
      await store.saveProfileSource('p1', 'mixed-port: 1080\n');
      expect(files.contents['p1'], 'mixed-port: 1080\n');
      expect(store.isMaterialised('p1'), isFalse);
    });
  });

  group('saving an overlay', () {
    test('snapshots the base and materialises the profile', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );

      expect(store.hasOverlay('p1'), isTrue);
      expect(store.isMaterialised('p1'), isTrue);
      expect(await store.readProfileSource('p1'), _profileYaml);
      expect(rulesOf(files.contents['p1']!), <String>[
        'DOMAIN,x.com,PROXY',
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'MATCH,PROXY',
      ]);
    });

    test('a second save re-materialises from the base, not the result', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,y.com,PROXY']),
        ),
      );

      // Not x AND y: the first override is gone, replaced by the second.
      expect(rulesOf(files.contents['p1']!), <String>[
        'DOMAIN,y.com,PROXY',
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'MATCH,PROXY',
      ]);
    });

    test('a patch is deep-merged', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          patch: <String, dynamic>{'mixed-port': 1080},
        ),
      );
      expect(parseYamlMap(files.contents['p1']!)['mixed-port'], 1080);
    });

    test('a schedule-only overlay is stored but changes no config', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          schedule: ProfileSchedule(cron: '0 * * * *'),
        ),
      );
      expect(store.hasOverlay('p1'), isTrue);
      expect(store.isMaterialised('p1'), isFalse);
      expect(files.contents['p1'], _profileYaml);
      expect((await store.readOverlay('p1')).overlay.schedule.cron, '0 * * * *');
    });

    test('dropping to a schedule-only overlay restores the pristine file', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      expect(store.isMaterialised('p1'), isTrue);

      await store.saveOverlay(
        'p1',
        const ProfileOverlay(schedule: ProfileSchedule(fixedInterval: true)),
      );
      expect(store.isMaterialised('p1'), isFalse);
      expect(files.contents['p1'], _profileYaml);
    });

    test('an empty overlay clears everything', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      await store.saveOverlay('p1', ProfileOverlay.empty);

      expect(store.hasOverlay('p1'), isFalse);
      expect(store.isMaterialised('p1'), isFalse);
      expect(files.contents['p1'], _profileYaml);
    });

    test('raw source is kept verbatim so comments survive', () async {
      const source = '''
# my notes
rules:
  prepend:
    - DOMAIN,x.com,PROXY
''';
      await store.saveOverlay(
        'p1',
        ProfileOverlay.fromYaml(parseYamlMap(source)),
        source: source,
      );
      expect((await store.readOverlay('p1')).source, source);
      expect(rulesOf(files.contents['p1']!).first, 'DOMAIN,x.com,PROXY');
    });

    test('a profile that does not parse is left alone', () async {
      files.contents['p2'] = 'rules: [\n';
      await store.saveOverlay(
        'p2',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      expect(files.contents['p2'], 'rules: [\n');
      expect(store.hasOverlay('p2'), isTrue);
    });
  });

  group('editing the profile under an overlay', () {
    test('the edit goes to the base and the overlay is re-applied', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );

      const edited = 'rules:\n  - MATCH,DIRECT\n';
      await store.saveProfileSource('p1', edited);

      expect(await store.readProfileSource('p1'), edited);
      expect(rulesOf(files.contents['p1']!), <String>[
        'DOMAIN,x.com,PROXY',
        'MATCH,DIRECT',
      ]);
    });
  });

  group('adopting a download', () {
    test('fresh content becomes the new base and keeps the overlay', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );

      // What ProfileStore.updateRemote would have written.
      const downloaded = 'rules:\n  - GEOIP,JP,DIRECT\n  - MATCH,PROXY\n';
      files.contents['p1'] = downloaded;
      await store.adoptDownloadedProfile('p1');

      expect(await store.readProfileSource('p1'), downloaded);
      expect(rulesOf(files.contents['p1']!), <String>[
        'DOMAIN,x.com,PROXY',
        'GEOIP,JP,DIRECT',
        'MATCH,PROXY',
      ]);
    });

    test('a 304 does not apply the overlay twice', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      final materialised = files.contents['p1']!;

      // A conditional GET that came back 304 leaves the file untouched.
      await store.adoptDownloadedProfile('p1');

      expect(files.contents['p1'], materialised);
      expect(rulesOf(files.contents['p1']!), <String>[
        'DOMAIN,x.com,PROXY',
        'DOMAIN,a.com,DIRECT',
        'GEOIP,CN,DIRECT',
        'MATCH,PROXY',
      ]);
      expect(await store.readProfileSource('p1'), _profileYaml);
    });

    test('with no overlay it does nothing', () async {
      files.contents['p1'] = 'rules: []\n';
      await store.adoptDownloadedProfile('p1');
      expect(files.contents['p1'], 'rules: []\n');
      expect(store.isMaterialised('p1'), isFalse);
    });
  });

  group('clearing and forgetting', () {
    test('clearOverlay puts the pristine profile back', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(delete: <String>['GEOIP,CN,DIRECT']),
        ),
      );
      expect(rulesOf(files.contents['p1']!), hasLength(2));

      await store.clearOverlay('p1');
      expect(files.contents['p1'], _profileYaml);
      expect(store.hasOverlay('p1'), isFalse);
      expect(store.isMaterialised('p1'), isFalse);
    });

    test('forget removes both sidecars without touching the profile', () async {
      await store.saveOverlay(
        'p1',
        const ProfileOverlay(
          rules: RuleOverlay(prepend: <String>['DOMAIN,x.com,PROXY']),
        ),
      );
      final materialised = files.contents['p1']!;

      await store.forget('p1');
      expect(store.overlayFile('p1').existsSync(), isFalse);
      expect(store.baseFile('p1').existsSync(), isFalse);
      expect(files.contents['p1'], materialised);
    });
  });

  group('reading a broken overlay', () {
    test('the source is still returned so the editor can open it', () async {
      await store.overlayFile('p1').writeAsString('rules: [\n');
      final stored = await store.readOverlay('p1');
      expect(stored.exists, isTrue);
      expect(stored.source, 'rules: [\n');
      expect(stored.overlay, ProfileOverlay.empty);
    });
  });

  test('an unsafe profile id is refused before it reaches the filesystem', () {
    expect(() => store.overlayFile('../escape'), throwsArgumentError);
    expect(() => store.baseFile('..'), throwsArgumentError);
  });
}
