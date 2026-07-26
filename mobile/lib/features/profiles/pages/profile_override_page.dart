/// The override document, in an editor.
///
/// Port of `pages/override.tsx` plus `components/override/edit-file-modal.tsx`,
/// collapsed into one screen. The desktop keeps overrides as a separate library
/// of documents that profiles subscribe to, and lets a document be JavaScript
/// or YAML. Neither survives the port:
///
///  * **One document per profile.** `ProfileItem` has no `override: string[]`
///    field, and a shared library whose membership cannot be persisted is a
///    library that silently forgets what it was attached to. One document per
///    profile has the same expressive power for a phone and no way to go wrong.
///  * **YAML only.** The desktop refuses a JavaScript override outright
///    (`override.ts`: *"JavaScript overrides are disabled on Windows because it
///    is not a security boundary; convert it to a declarative YAML override"*).
///    This port never offers the choice, so there is nothing to refuse.
library;

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_error_text.dart';
import '../data/profile_overlay_store.dart';
import '../data/profiles_providers.dart';
import '../data/rule_overlay.dart';
import '../data/yaml_document.dart';
import 'yaml_editor_page.dart';

Future<void> pushProfileOverride(BuildContext context, ProfileItem item) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileOverridePage(item: item)),
    );

class ProfileOverridePage extends ConsumerWidget {
  const ProfileOverridePage({super.key, required this.item});

  final ProfileItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final stored = ref.watch(profileOverlayProvider(item.id));

    return stored.when(
      loading: () => AikoScaffold(
        title: l10n.t('override.editInfo.title'),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => AikoScaffold(
        title: l10n.t('override.title'),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.t('common.error.default'),
          message: redactProfileMessage(error.toString()),
        ),
      ),
      data: (overlay) => YamlEditorPage(
        title: l10n.t('override.title'),
        subtitle: item.name,
        notice: l10n.t('override.defaultContent.yaml'),
        initialText: overlay.exists ? overlay.source : kOverlayTemplate,
        resetLabel: l10n.t('override.menuItems.delete'),
        onReset: overlay.exists
            ? () => ref.read(profilesControllerProvider).clearOverlay(item.id)
            : null,
        onSave: (edited) => _save(ref, edited),
      ),
    );
  }

  /// The editor has already checked that [edited] parses; this turns it into a
  /// document and keeps the user's own text so comments and key order survive
  /// the round trip.
  Future<void> _save(WidgetRef ref, String edited) async {
    final document = ProfileOverlay.fromYaml(parseYamlMap(edited));
    await ref
        .read(profilesControllerProvider)
        .saveOverlay(
          item.id,
          document,
          source: document.isEmpty ? null : edited,
        );
  }
}
