/// Overrides on disk, and the materialisation that makes them take effect.
///
/// ## Why materialise
///
/// On the desktop, overrides are applied while the runtime config is generated
/// (`src/main/core/factory.ts`). On Android the equivalent step lives in
/// `AikoCoreController.start()`, which reads the profile with
/// `ProfileStore.readClashConfig(id)` and hands it straight to the converter —
/// there is no hook between the two. So instead of applying the overlay at
/// generation time, this store keeps the overridden result *as* the profile the
/// core reads, and keeps the pristine original beside it:
///
/// ```
/// profiles/<id>.yaml            what the core reads  = base + overlay
/// profiles/<id>.base.yaml       the pristine original, only while an overlay exists
/// profiles/<id>.override.yaml   the overlay document
/// ```
///
/// The invariant is: **`<id>.base.yaml` exists if and only if
/// `<id>.override.yaml` describes something that changes the config**, and
/// whenever it exists, `<id>.yaml` is derived from it. Every entry point below
/// re-establishes that invariant before returning, so there is no state where
/// the two disagree:
///
///  * [saveOverlay] snapshots the base on the first override and re-materialises.
///  * [adoptDownloadedProfile] is called right after a subscription refresh has
///    replaced `<id>.yaml` with fresh server content: that content becomes the
///    new base and the overlay is applied on top again. Without this an update
///    would silently drop the user's overrides — N5.
///  * [saveProfileSource] is a hand edit of the profile itself; it edits the
///    base, not the materialised file.
///  * [clearOverlay] restores the pristine file and removes both sidecars.
///
/// Writes to `<id>.yaml` go back through the caller's `ProfileStore`, so they
/// stay atomic and serialised per profile (N6). Writes to the sidecars use
/// `writeFileAtomically` from the same module for the same reason.
library;

import 'dart:async';
import 'dart:io';

import 'package:aikobox_mobile/core/config_store.dart';
import 'package:aikobox_mobile/core/paths.dart';
import 'package:path/path.dart' as p;

import 'rule_overlay.dart';
import 'yaml_document.dart';

/// Reads a profile's stored YAML. `ProfileStore.readProfileText`.
typedef ProfileTextReader = Future<String> Function(String id);

/// Writes a profile's stored YAML. `ProfileStore.writeProfileText`.
typedef ProfileTextWriter = Future<void> Function(String id, String content);

/// The header written above a freshly created override document, so a user who
/// opens the raw editor is not staring at an empty file.
const String kOverlayTemplate = '''
# AikoBox profile override.
#
# rules:    prepend / append / delete entries applied to the profile's rules.
#           A leading "<n>," pins an entry to index n instead of the edge.
# patch:    a YAML fragment deep-merged over the profile. "key!" replaces a
#           block outright, "+key" prepends to a list, "key+" appends to one.
# schedule: cron expression and fixed-interval flag for auto-update.
#
# JavaScript overrides are not supported, by design.
rules:
  prepend: []
  append: []
  delete: []
''';

/// A profile's override document plus the source text it was read from.
class StoredOverlay {
  const StoredOverlay({
    required this.overlay,
    required this.source,
    required this.exists,
  });

  static const StoredOverlay absent = StoredOverlay(
    overlay: ProfileOverlay.empty,
    source: '',
    exists: false,
  );

  final ProfileOverlay overlay;

  /// The document exactly as it is on disk — comments and all — so the raw
  /// editor round-trips instead of reformatting the user's file.
  final String source;

  final bool exists;
}

/// Overrides on disk for every profile.
class ProfileOverlayStore {
  ProfileOverlayStore({
    required this.dirs,
    required ProfileTextReader readProfile,
    required ProfileTextWriter writeProfile,
  }) : _readProfile = readProfile,
       _writeProfile = writeProfile;

  final AikoDirs dirs;
  final ProfileTextReader _readProfile;
  final ProfileTextWriter _writeProfile;

  final Map<String, SerialTaskQueue> _queues = <String, SerialTaskQueue>{};

  SerialTaskQueue _queueFor(String id) =>
      _queues.putIfAbsent(id, SerialTaskQueue.new);

  File overlayFile(String id) {
    assertSafeProfileId(id);
    return File(p.join(dirs.profilesDir.path, '$id.override.yaml'));
  }

  File baseFile(String id) {
    assertSafeProfileId(id);
    return File(p.join(dirs.profilesDir.path, '$id.base.yaml'));
  }

  /// Whether an override document exists for [id].
  bool hasOverlay(String id) => overlayFile(id).existsSync();

  /// Whether a pristine snapshot is being kept, i.e. the profile the core reads
  /// is a materialised one.
  bool isMaterialised(String id) => baseFile(id).existsSync();

  // -------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------

  /// Reads the override document. A document that does not parse is reported
  /// as an empty overlay with its source intact, so the raw editor can still
  /// open it and the user can fix the syntax.
  Future<StoredOverlay> readOverlay(String id) async {
    final file = overlayFile(id);
    if (!file.existsSync()) return StoredOverlay.absent;
    final source = await file.readAsString();
    ProfileOverlay overlay;
    try {
      overlay = ProfileOverlay.fromYaml(parseYamlMap(source));
    } on YamlDocumentException {
      overlay = ProfileOverlay.empty;
    }
    return StoredOverlay(overlay: overlay, source: source, exists: true);
  }

  /// The profile's own YAML — the pristine snapshot when one exists, otherwise
  /// the profile file itself. This is what the profile editor edits and what
  /// the rules editor treats as the base rule list.
  Future<String> readProfileSource(String id) async {
    final base = baseFile(id);
    if (base.existsSync()) return base.readAsString();
    return _readProfile(id);
  }

  // -------------------------------------------------------------------------
  // Writing
  // -------------------------------------------------------------------------

  /// Replaces the override document and re-materialises the profile.
  ///
  /// [source] lets the raw editor keep the user's own formatting; when it is
  /// omitted the document is re-emitted from [overlay].
  Future<void> saveOverlay(
    String id,
    ProfileOverlay overlay, {
    String? source,
  }) => _queueFor(id).enqueue(() async {
    await _ensureProfilesDir();

    if (overlay.isEmpty && source == null) {
      await _clearUnlocked(id);
      return;
    }

    // The base has to be captured before the first materialisation, while
    // `<id>.yaml` is still the untouched original.
    if (overlay.changesConfig && !baseFile(id).existsSync()) {
      await writeFileAtomically(baseFile(id), await _readProfile(id));
    }

    await writeFileAtomically(overlayFile(id), source ?? _emitOverlay(overlay));

    if (overlay.changesConfig) {
      await _materialiseUnlocked(id, overlay);
    } else if (baseFile(id).existsSync()) {
      // The overlay no longer changes anything (it only carries a schedule):
      // put the pristine file back and stop keeping a snapshot.
      await _writeProfile(id, await baseFile(id).readAsString());
      await _delete(baseFile(id));
    }
  });

  /// Saves a hand edit of the profile's own YAML.
  ///
  /// When an overlay is in force this writes the *base* and re-applies the
  /// overlay, so the two never fight: the user edits what the subscription
  /// said, and the override still sits on top of it.
  Future<void> saveProfileSource(String id, String content) =>
      _queueFor(id).enqueue(() async {
        await _ensureProfilesDir();
        final stored = await _readOverlayUnlocked(id);
        if (!stored.overlay.changesConfig) {
          await _writeProfile(id, content);
          await _delete(baseFile(id));
          return;
        }
        await writeFileAtomically(baseFile(id), content);
        await _materialiseUnlocked(id, stored.overlay);
      });

  /// Called after a subscription refresh. If the server actually sent new
  /// content, that content becomes the new base and the overlay is applied to
  /// it again; without this an update would silently drop the user's overrides
  /// (N5).
  ///
  /// A conditional GET that came back `304 Not Modified` leaves `<id>.yaml`
  /// untouched — and `<id>.yaml` is the *materialised* file, so adopting it as
  /// the base would apply the overlay a second time. The guard is to compare
  /// what is on disk against what the current base and overlay produce: equal
  /// means nothing was downloaded.
  Future<void> adoptDownloadedProfile(String id) =>
      _queueFor(id).enqueue(() async {
        final stored = await _readOverlayUnlocked(id);
        if (!stored.overlay.changesConfig) {
          await _delete(baseFile(id));
          return;
        }
        await _ensureProfilesDir();

        final base = baseFile(id);
        final downloaded = await _readProfile(id);
        if (base.existsSync()) {
          final expected = _materialise(
            await base.readAsString(),
            stored.overlay,
          );
          if (expected != null && expected == downloaded) return;
        }

        await writeFileAtomically(base, downloaded);
        await _materialiseUnlocked(id, stored.overlay);
      });

  /// Removes the override document and restores the pristine profile.
  Future<void> clearOverlay(String id) =>
      _queueFor(id).enqueue(() => _clearUnlocked(id));

  /// Drops every sidecar for a profile that no longer exists.
  Future<void> forget(String id) async {
    await _queueFor(id).enqueue(() async {
      await _delete(overlayFile(id));
      await _delete(baseFile(id));
    });
    _queues.remove(id);
  }

  /// Waits for every queued write to finish. Tests and shutdown paths use it.
  Future<void> drain() async {
    for (final queue in List<SerialTaskQueue>.of(_queues.values)) {
      await queue.drain();
    }
  }

  // -------------------------------------------------------------------------

  Future<StoredOverlay> _readOverlayUnlocked(String id) async {
    final file = overlayFile(id);
    if (!file.existsSync()) return StoredOverlay.absent;
    final source = await file.readAsString();
    try {
      return StoredOverlay(
        overlay: ProfileOverlay.fromYaml(parseYamlMap(source)),
        source: source,
        exists: true,
      );
    } on YamlDocumentException {
      return StoredOverlay(
        overlay: ProfileOverlay.empty,
        source: source,
        exists: true,
      );
    }
  }

  Future<void> _materialiseUnlocked(String id, ProfileOverlay overlay) async {
    final base = baseFile(id);
    final source = base.existsSync()
        ? await base.readAsString()
        : await _readProfile(id);
    final result = _materialise(source, overlay);
    // A profile that does not parse cannot be overridden. Leave the file
    // exactly as it is; the core reports the parse failure itself, which is a
    // far more useful message than anything invented here.
    if (result != null) await _writeProfile(id, result);
  }

  /// [source] with [overlay] applied, or null when [source] is not valid YAML.
  static String? _materialise(String source, ProfileOverlay overlay) {
    try {
      return emitYaml(applyProfileOverlay(parseYamlMap(source), overlay));
    } on YamlDocumentException {
      return null;
    }
  }

  Future<void> _clearUnlocked(String id) async {
    final base = baseFile(id);
    if (base.existsSync()) {
      await _writeProfile(id, await base.readAsString());
    }
    await _delete(base);
    await _delete(overlayFile(id));
  }

  Future<void> _ensureProfilesDir() async {
    if (!dirs.profilesDir.existsSync()) {
      await dirs.profilesDir.create(recursive: true);
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // A sidecar that refuses to go is not worth failing a save over; the
      // next write overwrites it anyway.
    }
  }

  static String _emitOverlay(ProfileOverlay overlay) {
    final document = overlay.toYaml();
    if (document.isEmpty) return kOverlayTemplate;
    return emitYaml(document);
  }
}
