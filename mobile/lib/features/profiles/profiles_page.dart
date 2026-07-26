/// The profiles list.
///
/// Port of `src/renderer/src/pages/profiles.tsx`, minus the two things that do
/// not exist on Android: the drag-and-drop file target (there is nothing to
/// drop onto) and the `.cpx` plugin gateway (Windows-only).
///
/// The desktop keeps the URL bar permanently at the top of the page. Here the
/// three ways to add a profile live behind one `+` action, because the import
/// form has eight fields and a phone has one column.
library;

import 'dart:convert';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/profile_batch_update.dart';
import 'data/profile_error_text.dart';
import 'data/profiles_providers.dart';
import 'widgets/profile_card.dart';
import 'widgets/profile_messages.dart';
import 'widgets/subscription_qr_sheet.dart';
import 'pages/profile_editor_page.dart';
import 'pages/profile_override_page.dart';
import 'pages/profile_rules_page.dart';
import 'pages/profile_source_page.dart';

class ProfilesPage extends ConsumerWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final profiles = ref.watch(profilesProvider);
    final busy = ref.watch(profilesBusyProvider);
    final currentId = ref.watch(currentProfileIdProvider);

    return AikoScaffold(
      title: l10n.t('profiles.title'),
      actions: <Widget>[
        IconButton(
          tooltip: l10n.t('profiles.updateAll'),
          onPressed: busy.isBusy ? null : () => _updateAll(context, ref),
          icon: busy.updatingAll
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: l10n.t('common.add'),
          onPressed: busy.isBusy ? null : () => _showAddSheet(context, ref),
          icon: const Icon(Icons.add_rounded),
        ),
        const SizedBox(width: 4),
      ],
      body: Column(
        children: <Widget>[
          if (busy.updatingAll)
            _BatchProgress(done: busy.batchDone, total: busy.batchTotal),
          Expanded(
            child: profiles.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.error_outline_rounded,
                title: l10n.t('common.error.default'),
                message: redactProfileMessage(error.toString()),
                action: FilledButton.tonal(
                  onPressed: () => ref.invalidate(profilesProvider),
                  child: Text(l10n.t('common.retry')),
                ),
              ),
              data: (items) => items.isEmpty
                  ? EmptyState(
                      icon: Icons.cloud_download_outlined,
                      title: l10n.t('profiles.empty.title'),
                      message: l10n.t('profiles.empty.description'),
                      action: FilledButton.tonalIcon(
                        onPressed: () => _showAddSheet(context, ref),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(l10n.t('profiles.import')),
                      ),
                    )
                  : _ProfileList(
                      items: items,
                      currentId: currentId,
                      busy: busy,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchProgress extends StatelessWidget {
  const _BatchProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AikoDims.pagePadding, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            total == 0
                ? l10n.t('profiles.updating')
                : '${l10n.t('profiles.updating')} $done / $total',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? null : done / total,
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileList extends ConsumerWidget {
  const _ProfileList({
    required this.items,
    required this.currentId,
    required this.busy,
  });

  final List<ProfileItem> items;
  final String? currentId;
  final ProfilesBusy busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        0,
        AikoDims.pagePadding,
        AikoDims.fabClearance,
      ),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorderItem: (oldIndex, newIndex) {
        if (busy.isBusy) return;
        _reorder(context, ref, oldIndex, newIndex);
      },
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        elevation: 6,
        borderRadius: BorderRadius.circular(AikoDims.cardRadius),
        child: child,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          key: ValueKey<String>(item.id),
          padding: const EdgeInsets.only(bottom: AikoDims.gridSpacing),
          child: Consumer(
            builder: (context, ref, _) {
              final overlay = ref.watch(profileOverlayProvider(item.id));
              return ProfileCard(
                item: item,
                isCurrent: item.id == currentId,
                isRefreshing: busy.isRefreshing(item.id),
                isBusy: busy.isBusy,
                hasOverride: overlay.value?.overlay.isNotEmpty ?? false,
                dragHandle: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_indicator_rounded),
                ),
                onSelect: () => _select(context, ref, item),
                onAction: (action) => _handle(context, ref, item, action),
              );
            },
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Persists a drag-reorder. A failure leaves the stored order alone and the
/// list rebuilds from it, so the row simply springs back.
Future<void> _reorder(
  BuildContext context,
  WidgetRef ref,
  int oldIndex,
  int newIndex,
) async {
  try {
    await ref.read(profilesControllerProvider).reorder(oldIndex, newIndex);
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.saveProfileConfigFailed',
    );
  }
}

Future<void> _select(
  BuildContext context,
  WidgetRef ref,
  ProfileItem item,
) async {
  final l10n = context.l10n;
  try {
    await ref.read(profilesControllerProvider).select(item.id);
    if (!context.mounted) return;
    showProfileMessage(
      context,
      l10n.t(
        'profiles.switchSuccess',
        args: <String, Object?>{'name': item.name},
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.switchProfileFailed',
    );
  }
}

Future<void> _handle(
  BuildContext context,
  WidgetRef ref,
  ProfileItem item,
  ProfileCardAction action,
) async {
  switch (action) {
    case ProfileCardAction.refresh:
      await _refresh(context, ref, item);
    case ProfileCardAction.editInfo:
      await pushProfileEditor(context, item);
    case ProfileCardAction.editFile:
      await pushProfileSource(context, item);
    case ProfileCardAction.editRules:
      await pushProfileRules(context, item);
    case ProfileCardAction.editOverride:
      await pushProfileOverride(context, item);
    case ProfileCardAction.showQrCode:
      final url = item.url;
      if (url != null && url.isNotEmpty) {
        await showSubscriptionQrSheet(context, name: item.name, url: url);
      }
    case ProfileCardAction.openHome:
      await _openHome(context, item);
    case ProfileCardAction.delete:
      await _delete(context, ref, item);
  }
}

Future<void> _refresh(
  BuildContext context,
  WidgetRef ref,
  ProfileItem item,
) async {
  try {
    await ref.read(profilesControllerProvider).refresh(item.id);
    if (!context.mounted) return;
    showProfileMessage(context, context.l10n.t('profiles.updated'));
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.updateProfileFailed',
    );
  }
}

Future<void> _delete(
  BuildContext context,
  WidgetRef ref,
  ProfileItem item,
) async {
  final l10n = context.l10n;
  final confirmed = await showAikoConfirmSheet(
    context,
    title: l10n.t('profiles.deleteConfirm.title'),
    message: l10n.t(
      'profiles.deleteConfirm.content',
      args: <String, Object?>{'name': item.name},
    ),
    confirmLabel: l10n.t('common.delete'),
    cancelLabel: l10n.t('common.cancel'),
    icon: Icons.delete_outline_rounded,
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;

  try {
    await ref.read(profilesControllerProvider).remove(item.id);
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.deleteProfileFailed',
    );
  }
}

Future<void> _openHome(BuildContext context, ProfileItem item) async {
  final home = item.home;
  if (home == null || home.isEmpty) return;
  final uri = Uri.tryParse(home);
  // Only https, and only because the header that supplied it was already
  // checked for that by the profile store — belt and braces.
  if (uri == null || uri.scheme != 'https') return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(context, error);
  }
}

Future<void> _updateAll(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  try {
    final result = await ref.read(profilesControllerProvider).updateAll();
    if (!context.mounted) return;

    if (result.isEmpty) {
      showProfileMessage(
        context,
        l10n.t('profiles.notification.updateAllEmpty'),
      );
      return;
    }
    if (result.allSucceeded) {
      showProfileMessage(
        context,
        l10n.t(
          'profiles.notification.updateAllSuccess',
          args: <String, Object?>{'count': result.succeeded},
        ),
      );
      return;
    }

    final headline = result.allFailed
        ? l10n.t(
            'profiles.notification.updateAllFailed',
            args: <String, Object?>{'count': result.failed},
          )
        : l10n.t(
            'profiles.notification.updateAllPartial',
            args: <String, Object?>{
              'succeeded': result.succeeded,
              'failed': result.failed,
            },
          );
    _showBatchFailures(context, headline, result);
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.updateProfileFailed',
    );
  }
}

void _showBatchFailures(
  BuildContext context,
  String headline,
  ProfileBatchResult result,
) {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(headline),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: l10n.t('common.details'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(headline),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final failure in result.failures)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(describeBatchFailure(l10n, failure)),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.t('common.close')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
}

// ---------------------------------------------------------------------------
// Adding
// ---------------------------------------------------------------------------

Future<void> _showAddSheet(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final choice = await showModalBottomSheet<_AddChoice>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SectionList(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 8),
          sections: <SectionListSection>[
            SectionListSection(
              title: l10n.t('profiles.import'),
              tiles: <SectionListTile>[
                SectionListTile(
                  title: l10n.t('profiles.importFromUrl'),
                  icon: Icons.link_rounded,
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_AddChoice.url),
                ),
                SectionListTile(
                  title: l10n.t('profiles.importFromFile'),
                  icon: Icons.folder_open_rounded,
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_AddChoice.file),
                ),
                SectionListTile(
                  title: l10n.t('profiles.createEmpty'),
                  icon: Icons.note_add_outlined,
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_AddChoice.empty),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _AddChoice.url:
      await pushImportSubscription(context);
    case _AddChoice.file:
      await _importFile(context, ref);
    case _AddChoice.empty:
      await _createEmpty(context, ref);
  }
}

enum _AddChoice { url, file, empty }

/// The blank profile the desktop's "new" action creates, verbatim.
const String kEmptyProfileContent = 'proxies: []\n'
    'proxy-groups: []\n'
    'rules: []\n';

Future<void> _createEmpty(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  try {
    await ref
        .read(profilesControllerProvider)
        .importLocal(
          name: l10n.t('profiles.newProfile'),
          content: kEmptyProfileContent,
        );
    if (!context.mounted) return;
    showProfileMessage(context, l10n.t('common.saved'));
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.addProfileFailed',
    );
  }
}

Future<void> _importFile(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  FilePickerResult? picked;
  try {
    picked = await FilePicker.pickFiles(
      dialogTitle: l10n.t('common.dialog.selectSubscriptionFile'),
      type: FileType.custom,
      allowedExtensions: const <String>['yaml', 'yml'],
      // Android's document provider hands back a content:// URI that may not
      // resolve to a readable path, so ask for the bytes instead.
      withData: true,
    );
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.addProfileFailed',
    );
    return;
  }

  if (picked == null || picked.files.isEmpty || !context.mounted) return;
  final file = picked.files.first;

  final lower = file.name.toLowerCase();
  if (!lower.endsWith('.yaml') && !lower.endsWith('.yml')) {
    showProfileMessage(context, l10n.t('profiles.error.unsupportedFileType'));
    return;
  }

  final bytes = file.bytes;
  if (bytes == null) {
    showProfileMessage(context, l10n.t('profiles.error.unsupportedFileType'));
    return;
  }

  try {
    await ref
        .read(profilesControllerProvider)
        .importLocal(
          name: file.name,
          // A picked file is as untrusted as a downloaded one; `importLocal`
          // runs it through the same normaliser and the same bounds check.
          content: utf8.decode(bytes, allowMalformed: true),
        );
    if (!context.mounted) return;
    showProfileMessage(
      context,
      l10n.t('profiles.notification.importSuccess'),
    );
  } catch (error) {
    if (!context.mounted) return;
    showProfileError(
      context,
      error,
      fallbackKey: 'common.error.addProfileFailed',
    );
  }
}
