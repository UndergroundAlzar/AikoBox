/// The profile's own YAML, in an editor.
///
/// Port of `components/profiles/edit-file-modal.tsx`, including its warning
/// that a remote profile's edits are replaced the next time the subscription
/// updates — which is exactly what the override editor is for.
///
/// When an override *is* in force, this page edits the pristine snapshot rather
/// than the file the core reads, and re-applies the override on save. Otherwise
/// hand-editing would silently bake the override into the base and then apply
/// it a second time.
library;

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_error_text.dart';
import '../data/profiles_providers.dart';
import 'yaml_editor_page.dart';

Future<void> pushProfileSource(BuildContext context, ProfileItem item) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileSourcePage(item: item)),
    );

class ProfileSourcePage extends ConsumerWidget {
  const ProfileSourcePage({super.key, required this.item});

  final ProfileItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final source = ref.watch(profileSourceProvider(item.id));

    return source.when(
      loading: () => AikoScaffold(
        title: l10n.t('profiles.editFile.title'),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => AikoScaffold(
        title: l10n.t('profiles.editFile.title'),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.t('common.error.default'),
          message: redactProfileMessage(error.toString()),
        ),
      ),
      data: (text) => YamlEditorPage(
        title: l10n.t('profiles.editFile.title'),
        subtitle: item.name,
        // The desktop's sentence trails off into a link to the override
        // feature; here the two words are simply appended.
        notice: item.isRemote
            ? '${l10n.t('profiles.editFile.notice')} '
                  '${l10n.t('profiles.editFile.override')} '
                  '${l10n.t('profiles.editFile.feature')}'
            : null,
        initialText: text,
        onSave: (edited) => ref
            .read(profilesControllerProvider)
            .saveProfileSource(item.id, edited),
      ),
    );
  }
}
